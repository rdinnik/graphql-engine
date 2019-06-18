{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DisambiguateRecordFields #-}
module Hasura.GraphQL.Execute
  ( QExecPlanResolved(..)
  , QExecPlanPartial(..)
  , Batch(..)
  , getExecPlanPartial
  , extractRemoteRelArguments
  , produceBatches
  , joinResults

  , ExecOp(..)
  , getResolvedExecPlan
  , execRemoteGQ

  , EP.PlanCache
  , EP.initPlanCache
  , EP.clearPlanCache
  , EP.dumpPlanCache
  ) where

import           Control.Exception (try)
import           Control.Lens
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as L8
import           Data.Scientific
import           Data.Validation
import qualified Data.Vector as V
import           Hasura.SQL.Types

import           Data.Has
import           Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import           Data.Time
import           Debug.Trace
import           Hasura.GraphQL.Validate.Field
import           Hasura.SQL.Time

import qualified Data.HashMap.Strict.InsOrd as OHM
import qualified Data.Aeson as J
import qualified Data.CaseInsensitive as CI
import qualified Data.HashMap.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.String.Conversions as CS
import qualified Data.Text as T
import qualified Language.GraphQL.Draft.Syntax as G
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Types as N
import qualified Network.Wreq as Wreq

import           Hasura.EncJSON
import           Hasura.GraphQL.Context
import           Hasura.GraphQL.Resolve.Context
import           Hasura.GraphQL.Schema
import           Hasura.GraphQL.Transport.HTTP.Protocol
import           Hasura.SQL.Value
import           Hasura.GraphQL.Validate.Types
import           Hasura.HTTP
import           Hasura.Prelude
import           Hasura.RQL.DDL.Remote.Input
import           Hasura.RQL.DDL.Headers
import           Hasura.RQL.Types
import           Hasura.Server.Context
import           Hasura.Server.Utils                    (bsToTxt,
                                                         filterRequestHeaders)
import           Hasura.RQL.DDL.Remote.Types

import qualified Hasura.GraphQL.Execute.LiveQuery as EL
import qualified Hasura.GraphQL.Execute.Plan as EP
import qualified Hasura.GraphQL.Execute.Query as EQ

import qualified Hasura.GraphQL.Resolve as GR
import qualified Hasura.GraphQL.Validate as VQ

-- The current execution plan of a graphql operation, it is
-- currently, either local pg execution or a remote execution
data QExecPlanPartial
  = ExPHasuraPartial !(GCtx, VQ.HasuraTopField, [G.VariableDefinition])
  | ExPRemotePartial !VQ.RemoteTopQuery

-- The current execution plan of a graphql operation, it is
-- currently, either local pg execution or a remote execution
data QExecPlanResolved
  = ExPHasura !ExecOp
  | ExPRemote !VQ.RemoteTopQuery
  | ExPMixed !ExecOp (NonEmpty RemoteRelField)

newtype RemoteRelKey =
  RemoteRelKey Int
  deriving (Eq, Ord, Show, Hashable)

data RemoteRelField =
  RemoteRelField
    { rrRemoteField :: !RemoteField
    , rrField :: !Field
    , rrRelFieldPath :: !RelFieldPath
    , rrAlias :: !G.Alias
    , rrPhantomFields :: ![Text]
    }
  deriving (Show)

newtype RelFieldPath = RelFieldPath (Seq.Seq G.Alias)
  deriving (Show, Monoid, Semigroup, Eq)

data InsertPath =
  InsertPath
    { ipFields :: !(Seq.Seq Text)
    , ipIndex :: !(Maybe ArrayIndex)
    }
  deriving (Show, Eq)

newtype ArrayIndex =
  ArrayIndex Int
  deriving (Show, Eq, Ord)

getExecPlanPartial
  :: (MonadError QErr m)
  => UserInfo
  -> SchemaCache
  -> Bool
  -> GQLReqParsed
  -> m (Seq.Seq QExecPlanPartial)
getExecPlanPartial userInfo sc enableAL req = do

  -- check if query is in allowlist
  when enableAL checkQueryInAllowlist

  (gCtx, _)  <- flip runStateT sc $ getGCtx role gCtxRoleMap
  queryParts <- flip runReaderT gCtx $ VQ.getQueryParts req

  topFields <- runReaderT (VQ.validateGQ queryParts) gCtx
  let varDefs = G._todVariableDefinitions $ VQ.qpOpDef queryParts
  return $
    fmap
      (\case
          VQ.HasuraTopField hasuraTopField ->
            ExPHasuraPartial (gCtx, hasuraTopField, varDefs)
          VQ.RemoteTopField remoteTopField -> ExPRemotePartial remoteTopField)
      topFields

  where
    role = userRole userInfo
    gCtxRoleMap = scGCtxMap sc

    checkQueryInAllowlist =
      -- only for non-admin roles
      when (role /= adminRole) $ do
        let notInAllowlist =
              not $ VQ.isQueryInAllowlist (_grQuery req) (scAllowlist sc)
        when notInAllowlist $ modifyQErr modErr $ throwVE "query is not allowed"

    modErr e =
      let msg = "query is not in any of the allowlists"
      in e{qeInternal = Just $ J.object [ "message" J..= J.String msg]}

-- An execution operation, in case of
-- queries and mutations it is just a transaction
-- to be executed
data ExecOp
  = ExOpQuery !LazyRespTx
  | ExOpMutation !LazyRespTx
  | ExOpSubs !EL.LiveQueryOp

getResolvedExecPlan
  :: (MonadError QErr m, MonadIO m)
  => PGExecCtx
  -> EP.PlanCache
  -> UserInfo
  -> SQLGenCtx
  -> Bool
  -> SchemaCache
  -> SchemaCacheVer
  -> GQLReqUnparsed
  -> m (Seq.Seq QExecPlanResolved)
getResolvedExecPlan pgExecCtx planCache userInfo sqlGenCtx enableAL sc scVer reqUnparsed = do
  planM <-
    liftIO $ EP.getPlan scVer (userRole userInfo) opNameM queryStr planCache
  let usrVars = userVars userInfo
  case planM
    -- plans are only for queries and subscriptions
        of
    Just plan ->
      pure . ExPHasura <$>
      case plan of
        EP.RPQuery queryPlan ->
          ExOpQuery <$> EQ.queryOpFromPlan usrVars queryVars queryPlan
        EP.RPSubs subsPlan ->
          ExOpSubs <$> EL.subsOpFromPlan pgExecCtx usrVars queryVars subsPlan
    Nothing -> noExistingPlan
  where
    GQLReq opNameM queryStr queryVars = reqUnparsed
    addPlanToCache plan =
      liftIO $
      EP.addPlan scVer (userRole userInfo) opNameM queryStr plan planCache
    noExistingPlan = do
      req <- toParsed reqUnparsed
      partialExecPlans <- getExecPlanPartial userInfo sc enableAL req
      forM partialExecPlans $ \partialExecPlan ->
        case partialExecPlan of
          ExPRemotePartial r -> pure (ExPRemote r)
          ExPHasuraPartial (gCtx, rootSelSet, varDefs) -> do
            case rootSelSet of
              VQ.HasuraTopMutation field ->
                ExPHasura . ExOpMutation <$>
                getMutOp gCtx sqlGenCtx userInfo (pure field)
              VQ.HasuraTopQuery originalField -> do
                let (constructor, alteredField) =
                      case rebuildFieldStrippingRemoteRels originalField of
                        Nothing -> (ExPHasura, originalField)
                        Just (newField, cursors) ->
                          trace
                            (unlines
                               [ "originalField = " ++ show originalField
                               , "newField = " ++ show newField
                               , "cursors = " ++ show (fmap rrRelFieldPath cursors)
                               ])
                            (flip ExPMixed cursors, newField)
                (queryTx, planM) <-
                  getQueryOp gCtx sqlGenCtx userInfo (pure alteredField) varDefs
                mapM_ (addPlanToCache . EP.RPQuery) planM
                return $ constructor $ ExOpQuery queryTx
              VQ.HasuraTopSubscription fld -> do
                (lqOp, planM) <-
                  getSubsOp
                    pgExecCtx
                    gCtx
                    sqlGenCtx
                    userInfo
                    reqUnparsed
                    varDefs
                    fld
                mapM_ (addPlanToCache . EP.RPSubs) planM
                return $ ExPHasura $ ExOpSubs lqOp

-- Rebuild the field with remote relationships removed, and paths that
-- point back to them.
rebuildFieldStrippingRemoteRels ::
     VQ.Field -> Maybe (VQ.Field, NonEmpty RemoteRelField)
rebuildFieldStrippingRemoteRels =
  extract . flip runState mempty . rebuild mempty
  where
    extract (field, remoteRelFields) =
      fmap (field, ) (NE.nonEmpty remoteRelFields)
    rebuild parentPath field0 = do
      selSetEithers <-
        traverse
          (\subfield ->
             case _fRemoteRel subfield of
               Nothing -> fmap Right (rebuild thisPath subfield)
               Just remoteField -> do
                 modify (remoteRelField :)
                 pure (Left remoteField)
                 where remoteRelField =
                         RemoteRelField
                           { rrRemoteField = remoteField
                           , rrField = subfield
                           , rrRelFieldPath = thisPath
                           , rrAlias = _fAlias subfield
                           , rrPhantomFields =
                               map
                                 G.unName
                                 (filter
                                    (\name ->
                                       notElem
                                         name
                                         (map _fName (toList (_fSelSet field0))))
                                    (map
                                       (G.Name . getFieldNameTxt)
                                       (toList
                                          (rtrHasuraFields
                                             (rmfRemoteRelationship remoteField)))))
                           })
          (_fSelSet field0)
      let fields = rights (toList selSetEithers)
      pure
        field0
          { _fSelSet =
              Seq.fromList
                (concatMap
                   (\case
                      Right field -> pure field
                        where _ = _fAlias field
                      Left remoteField ->
                        mapMaybe
                          (\name ->
                             if elem name (map _fName fields)
                               then Nothing
                               else Just
                                      (Field
                                         { _fAlias = G.Alias name
                                         , _fName = name
                                         , _fType =
                                             G.NamedType (G.Name "unknown3")
                                         , _fArguments = mempty
                                         , _fSelSet = mempty
                                         , _fRemoteRel = Nothing
                                         }))
                          (map
                             (G.Name . getFieldNameTxt)
                             (toList
                                (rtrHasuraFields
                                   (rmfRemoteRelationship remoteField)))))
                   (toList selSetEithers))
          }
      where
        thisPath = parentPath <> RelFieldPath (pure (_fAlias field0))

-- | Get a list of fields needed from a hasura result.
neededHasuraFields
  :: RemoteField -> [FieldName]
neededHasuraFields remoteField = toList (rtrHasuraFields remoteRelationship)
  where
    remoteRelationship = rmfRemoteRelationship remoteField

-- remote result = {"data":{"result_0":{"name":"alice"},"result_1":{"name":"bob"},"result_2":{"name":"alice"}}}

-- | Join the data from the original hasura with the remote values.
joinResults :: [(Batch, EncJSON)]
            -> Map.HashMap Text J.Value
            -> Either String (Map.HashMap Text J.Value)
joinResults paths hasuraValue0 = do
  remoteValues :: [(Batch, Map.HashMap Text J.Value)] <-
    mapM
      (\(batch, encJson) ->
         case J.eitherDecode (encJToLBS encJson) of
           Left err -> Left ("joinResults: eitherDecode: " <> err)
           Right object ->
             case Map.lookup ("data" :: Text) object of
               Nothing -> Left "No data key in payload!"
               Just hash -> pure (batch, hash))
      paths
  foldM
    (\hasuraValue (batch, remoteValue) ->
       insertBatchResults remoteValue batch hasuraValue)
    hasuraValue0
    remoteValues

-- | Insert at path, index the value in the larger structure.
insertBatchResults ::
     Map.HashMap Text J.Value
  -> Batch
  -> Map.HashMap Text J.Value
  -> Either String (Map.HashMap Text J.Value)
insertBatchResults remoteHash batch hasuraHash0 =
  inHashmap (batchRelFieldPath batch) hasuraHash0
  where
    cardinality = biCardinality (batchInputs batch)
    inHashmap (RelFieldPath Seq.Empty) hasuraHash =
      case cardinality of
        One ->
          Right
            (foldl'
               (flip Map.delete)
               (Map.insert
                  (batchRelationshipKeyToMake batch)
                  (peelOffNestedFields
                     (batchNestedFields batch)
                     (J.Object remoteHash))
                  hasuraHash)
               (batchPhantoms batch))
        Many ->
          Left
            ("Cardinality mismatch with result: expected array but got object.")
    inHashmap (RelFieldPath (G.Alias (G.Name key) Seq.:<| rest)) hasuraHash =
      case Map.lookup key hasuraHash of
        Nothing ->
          Left
            ("Couldn't find expected key " <> show key <> " in " <>
             L8.unpack (J.encode hasuraHash) <>
             ", while traversing " <>
             L8.unpack (J.encode hasuraHash0))
        Just hasuraValue ->
          fmap
            (\hasuraValue' -> Map.insert key hasuraValue' hasuraHash)
            (inValue (RelFieldPath rest) hasuraValue)
    inValue path hasuraValue =
      case hasuraValue of
        J.Object hasuraHash -> J.Object <$> (inHashmap path hasuraHash)
        J.Array values ->
          case path of
            RelFieldPath Seq.Empty ->
              case cardinality of
                Many ->
                  fmap
                    J.Array
                    (sequence
                       (V.zipWith
                          (\arrayIndex hasuraRowValue ->
                             case hasuraRowValue of
                               J.Object hasuraRowHash ->
                                 case Map.lookup
                                        (arrayIndexText arrayIndex)
                                        remoteHash of
                                   Nothing ->
                                     Left
                                       ("Couldn't find remote row for " <>
                                        show arrayIndex <>
                                        " in " <>
                                        L8.unpack (J.encode remoteHash))
                                   Just remoteRowValue ->
                                     pure
                                       (J.Object
                                          (foldl'
                                             (flip Map.delete)
                                             (Map.insert
                                                (batchRelationshipKeyToMake
                                                   batch)
                                                (peelOffNestedFields
                                                   (batchNestedFields batch)
                                                   remoteRowValue)
                                                hasuraRowHash)
                                             (batchPhantoms batch)))
                               _ ->
                                 Left
                                   ("Row result in hasura should be an object, but it's: " <>
                                    show hasuraRowValue))
                          (V.fromList (batchIndices batch))
                          values))
                One ->
                  Left
                    "Cardinality mismatch: found array in hasura value, but expected one."
            _ ->
              Left
                ("Encountered array too early: path=" <> show path <> ", value=" <>
                 L8.unpack (J.encode hasuraValue))
        _ ->
          Left
            ("Expected object or array in hasura value but got: " <>
             L8.unpack (J.encode hasuraValue))

-- | The drop 1 in here is dropping the first level of nesting. The
-- top field is already aliased to e.g. foo_idx_1, and that layer is
-- already peeled off. So here we are just peeling nested fields.
peelOffNestedFields :: NonEmpty G.Name -> J.Value -> J.Value
peelOffNestedFields xs toplevel = go (drop 1 (toList xs)) toplevel
  where
    go [] value = value
    go (G.Name key:rest) value =
      case value of
        J.Object hashmap ->
          case Map.lookup key hashmap of
            Nothing ->
              error
                ("Nein! " <> show key <> " in " <> show value <> " from " <>
                 show toplevel <>
                 " with " <>
                 show xs)
            Just value' -> go rest value'
        _ ->
          error
            ("No! " <> show key <> " in " <> show value <> " from " <>
             show toplevel <>
             " with " <>
             show xs)

-- | Produce the set of remote relationship batch requests.
produceBatches ::
     [( RemoteRelField
      , RemoteSchemaInfo
      , BatchInputs)]
  -> [Batch]
produceBatches =
  fmap
    (\(remoteRelField, remoteSchemaInfo, rows) ->
       produceBatch remoteSchemaInfo remoteRelField rows)

data Batch =
  Batch
    { batchRemoteTopQuery :: !VQ.RemoteTopQuery
    , batchRelFieldPath :: !RelFieldPath
    , batchIndices :: ![ArrayIndex]
    , batchRelationshipKeyToMake :: !Text
    , batchInputs :: !BatchInputs
    , batchNestedFields :: !(NonEmpty G.Name)
    , batchPhantoms :: ![Text]
    } deriving (Show)

-- | Produce batch queries for a given remote relationship.
produceBatch ::
     RemoteSchemaInfo
  -> RemoteRelField
  -> BatchInputs
  -> Batch
produceBatch remoteSchemaInfo remoteRelField inputs =
  Batch
    { batchRemoteTopQuery = remoteTopQuery
    , batchRelFieldPath = path
    , batchIndices = resultIndexes
    , batchRelationshipKeyToMake = G.unName (G.unAlias (rrAlias remoteRelField))
    , batchInputs = inputs
    , batchPhantoms = rrPhantomFields remoteRelField
    , batchNestedFields =
        fmap
          fcName
          (rtrRemoteFields
             (rmfRemoteRelationship (rrRemoteField remoteRelField)))
    }
  where
    remoteTopQuery =
      VQ.RemoteTopQuery
        { rtqRemoteSchemaInfo = remoteSchemaInfo
        , rtqFields =
            fmap
              (\(i, variables) ->
                 fieldCallsToField
                   (Just (arrayIndexAlias i))
                   (_fArguments originalField)
                   variables
                   (_fSelSet originalField)
                   (rtrRemoteFields remoteRelationship))
              indexedRows
        }
    indexedRows = zip (map ArrayIndex [0 :: Int ..]) (toList rows)
    rows = biRows inputs
    resultIndexes = map fst indexedRows
    remoteRelationship = rmfRemoteRelationship (rrRemoteField remoteRelField)
    path = rrRelFieldPath remoteRelField
    originalField = rrField remoteRelField

-- | Produce the alias name for a result index.
arrayIndexAlias :: ArrayIndex -> G.Alias
arrayIndexAlias i =
  G.Alias (G.Name (arrayIndexText i))

-- | Produce the alias name for a result index.
arrayIndexText :: ArrayIndex -> Text
arrayIndexText (ArrayIndex i) =
  T.pack ("hasura_array_idx_" ++ show i)

-- | Produce a field from the nested field calls.
fieldCallsToField ::
     Maybe G.Alias
  -> Map.HashMap G.Name AnnInpVal
  -> Map.HashMap G.Variable G.ValueConst
  -> SelSet
  -> NonEmpty FieldCall
  -> Field
fieldCallsToField mindexedAlias0 userProvidedArguments variables finalSelSet =
  nest mindexedAlias0
  where
    nest mindexedAlias (fieldCall :| rest) =
      Field
        { _fAlias =
            case mindexedAlias of
              Just indexedAlias -> indexedAlias
              Nothing -> G.Alias (fcName fieldCall)
        , _fName = fcName fieldCall
        , _fType = G.NamedType (G.Name "unknown_type")
        , _fArguments =
            let templatedArguments =
                  createArguments variables (fcArguments fieldCall)
             in case NE.nonEmpty rest of
                  Just {} -> templatedArguments
                  Nothing ->
                    Map.unionWith
                      mergeAnnInpVal
                      userProvidedArguments
                      templatedArguments
        , _fSelSet =
            case NE.nonEmpty rest of
              Nothing -> finalSelSet
              Just calls -> pure (nest Nothing calls)
        , _fRemoteRel = Nothing
        }

mergeAnnInpVal :: AnnInpVal -> AnnInpVal -> AnnInpVal
mergeAnnInpVal an1 an2 =
  an1 {_aivValue = mergeAnnGValue (_aivValue an1) (_aivValue an2)}

mergeAnnGValue :: AnnGValue -> AnnGValue -> AnnGValue
mergeAnnGValue (AGObject n1 (Just o1)) (AGObject _ (Just o2)) =
  (AGObject n1 (Just (mergeAnnGObject o1 o2)))
mergeAnnGValue (AGObject n1 (Just o1)) (AGObject _ Nothing) =
  (AGObject n1 (Just o1))
mergeAnnGValue (AGObject n1 Nothing) (AGObject _ (Just o1)) =
  (AGObject n1 (Just o1))
mergeAnnGValue (AGArray t (Just xs)) (AGArray _ (Just xs2)) =
  AGArray t (Just (xs <> xs2))
mergeAnnGValue (AGArray t (Just xs)) (AGArray _ Nothing) =
  AGArray t (Just xs)
mergeAnnGValue (AGArray t Nothing) (AGArray _ (Just xs)) =
    AGArray t (Just xs)
mergeAnnGValue x _ = x -- FIXME: Make error condition.

mergeAnnGObject :: AnnGObject -> AnnGObject -> AnnGObject
mergeAnnGObject = OHM.unionWith mergeAnnInpVal

-- | Create an argument map using the inputs taken from the hasura database.
createArguments ::
     Map.HashMap G.Variable G.ValueConst
  -> RemoteArguments
  -> Map.HashMap G.Name AnnInpVal
createArguments variables (RemoteArguments arguments) =
  either
    (error . show)
    (\xs -> Map.fromList (map (\(G.ObjectFieldG key val) -> (key, valueConstToAnnInpVal val)) xs))
    (toEither (substituteVariables variables arguments))

valueConstToAnnInpVal :: G.ValueConst -> AnnInpVal
valueConstToAnnInpVal vc =
  AnnInpVal
    { _aivType =
        G.TypeNamed (G.Nullability False) (G.NamedType (G.Name "unknown1"))
    , _aivVariable = Nothing
    , _aivValue = toAnnGValue vc
    }

toAnnGValue :: G.ValueConst -> AnnGValue
toAnnGValue =
  \case
    G.VCInt i -> AGScalar PGBigInt (Just (PGValInteger i))
    G.VCFloat v -> AGScalar PGFloat (Just (PGValDouble v))
    G.VCString (G.StringValue v) -> AGScalar PGText (Just (PGValText v))
    G.VCBoolean v -> AGScalar PGBoolean (Just (PGValBoolean v))
    G.VCNull -> AGScalar (PGUnknown "null") Nothing
    G.VCEnum {} -> AGScalar (PGUnknown "null") Nothing -- TODO: implement.
    G.VCList (G.ListValueG list) ->
      AGArray
        (G.ListType
           (G.TypeList
              (G.Nullability False)
              (G.ListType
                 (G.TypeNamed
                    (G.Nullability False)
                    (G.NamedType (G.Name "unknown2"))))))
        (pure (map valueConstToAnnInpVal list))
    G.VCObject (G.ObjectValueG keys) ->
      AGObject
        (G.NamedType (G.Name "unknown2"))
        (Just
           (OHM.fromList
              (map
                 (\(G.ObjectFieldG key val) -> (key, valueConstToAnnInpVal val))
                 keys)))

-- | Extract from the Hasura results the remote relationship arguments.
extractRemoteRelArguments ::
     RemoteSchemaMap
  -> EncJSON
  -> NonEmpty RemoteRelField
  -> Either String ( Map.HashMap Text J.Value
                   , [( RemoteRelField
                      , RemoteSchemaInfo
                      , BatchInputs)])
extractRemoteRelArguments remoteSchemaMap encJson rels =
  case J.eitherDecode (encJToLBS encJson) of
    Left err -> Left ("extractRemoteRelArguments: decode error: " <> err)
    Right object ->
      case Map.lookup ("data" :: Text) object of
        Nothing ->
          Left
            ("Couldn't find `data' payload in " <> L8.unpack (J.encode object))
        Just value -> do
          hash <-
            flip
              execStateT
              mempty
              (extractFromResult One keyedRemotes (J.Object value))
          remotes <-
            Map.traverseWithKey
              (\key rows ->
                 case Map.lookup key keyedMap of
                   Nothing -> Left "Failed to assicate remote key with remote."
                   Just remoteRel ->
                     case Map.lookup
                            (rtrRemoteSchema
                               (rmfRemoteRelationship (rrRemoteField remoteRel)))
                            remoteSchemaMap of
                       Just remoteSchemaInfo ->
                         pure (remoteRel, remoteSchemaInfo, rows)
                       Nothing -> Left "Couldn't find remote schema info!")
              hash
          pure (value, Map.elems remotes)
  where
    keyedRemotes = NE.zip (fmap RemoteRelKey (0 :| [1 ..])) rels
    keyedMap = Map.fromList (toList keyedRemotes)

data BatchInputs =
  BatchInputs
    { biRows :: !(Seq.Seq (Map.HashMap G.Variable G.ValueConst))
    , biCardinality :: Cardinality
    } deriving (Show)

instance Semigroup BatchInputs where
  (<>) (BatchInputs r1 c1) (BatchInputs r2 c2) =
    BatchInputs (r1 <> r2) (c1 <> c2)

data Cardinality = Many | One
 deriving (Eq, Show)

instance Semigroup Cardinality where
    (<>) _ Many = Many
    (<>) Many _ = Many
    (<>) One One = One

-- | Extract from a given result.
extractFromResult ::
     Cardinality
  -> NonEmpty (RemoteRelKey, RemoteRelField)
  -> J.Value
  -> StateT (Map.HashMap RemoteRelKey BatchInputs) (Either String) ()
extractFromResult cardinality keyedRemotes value =
  case value of
    J.Array values -> mapM_ (extractFromResult Many keyedRemotes) values
    J.Object hashmap -> do
      remotesRows :: Map.HashMap RemoteRelKey (Seq.Seq ( G.Variable
                                                       , G.ValueConst)) <-
        foldM
          (\result (key, remotes) ->
             case Map.lookup key hashmap of
               Just subvalue -> do
                 let (remoteRelKeys, unfinishedKeyedRemotes) =
                       partitionEithers (toList remotes)
                 case NE.nonEmpty unfinishedKeyedRemotes of
                   Nothing -> pure ()
                   Just subRemotes -> do
                     extractFromResult cardinality subRemotes subvalue
                 pure
                   (foldl'
                      (\result' remoteRelKey ->
                         Map.insertWith
                           (<>)
                           remoteRelKey
                           (pure
                              ( G.Variable (G.Name key)
                                -- TODO: Pay attention to variable naming wrt. aliasing.
                              , valueToValueConst subvalue))
                           result')
                      result
                      remoteRelKeys)
               Nothing ->
                 lift
                   (Left
                      ("Expected key " <> show key <> " at this position: " <>
                       L8.unpack (J.encode value))))
          mempty
          (Map.toList candidates)
      mapM_
        (\(remoteRelKey, row) ->
           modify
             (Map.insertWith
                (flip (<>))
                remoteRelKey
                (BatchInputs {biRows = pure (Map.fromList (toList row))
                             ,biCardinality = cardinality})))
        (Map.toList remotesRows)
    _ -> pure ()
  where
    candidates ::
         Map.HashMap Text (NonEmpty (Either RemoteRelKey ( RemoteRelKey
                                                         , RemoteRelField)))
    candidates =
      foldl'
        (\(!outerHashmap) keys ->
           foldl'
             (\(!innerHashmap) (key, remote) ->
                Map.insertWith (<>) key (pure remote) innerHashmap)
             outerHashmap
             keys)
        mempty
        (toList (fmap peelRemoteKeys keyedRemotes))

-- | Peel one layer of expected keys from the remote to be looked up
-- at the current level of the result object.
peelRemoteKeys ::
     (RemoteRelKey, RemoteRelField) -> [(Text, Either RemoteRelKey (RemoteRelKey, RemoteRelField))]
peelRemoteKeys (remoteRelKey, remoteRelField) =
  map
    (updatingRelPath . unconsPath)
    (neededHasuraFields (rrRemoteField remoteRelField))
  where
    updatingRelPath ::
         Either Text (Text, RelFieldPath)
      -> (Text, Either RemoteRelKey (RemoteRelKey, RemoteRelField))
    updatingRelPath result =
      case result of
        Right (key, remainingPath) ->
          ( key
          , Right (remoteRelKey, remoteRelField {rrRelFieldPath = remainingPath}))
        Left key -> (key, Left remoteRelKey)
    unconsPath :: FieldName -> Either Text (Text, RelFieldPath)
    unconsPath fieldName =
      case rrRelFieldPath remoteRelField of
        RelFieldPath Seq.Empty -> Left (getFieldNameTxt fieldName)
        RelFieldPath (G.Alias (G.Name key) Seq.:<| xs) -> Right (key, RelFieldPath xs)

-- | Convert a JSON value to a GraphQL value.
valueToValueConst :: J.Value -> G.ValueConst
valueToValueConst =
  \case
    J.Array xs -> G.VCList (G.ListValueG (fmap valueToValueConst (toList xs)))
    J.String str -> G.VCString (G.StringValue str)
    -- TODO: Note the danger zone of scientific:
    J.Number sci -> either G.VCFloat G.VCInt (floatingOrInteger sci)
    J.Null -> G.VCNull
    J.Bool b -> G.VCBoolean b
    J.Object hashmap ->
      G.VCObject
        (G.ObjectValueG
           (map
              (\(key, value) ->
                 G.ObjectFieldG (G.Name key) (valueToValueConst value))
              (Map.toList hashmap)))

-- Monad for resolving a hasura query/mutation
type E m =
  ReaderT ( UserInfo
          , OpCtxMap
          , TypeMap
          , FieldMap
          , OrdByCtx
          , InsCtxMap
          , SQLGenCtx
          ) (ExceptT QErr m)

runE
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> E m a
  -> m a
runE ctx sqlGenCtx userInfo action = do
  res <- runExceptT $ runReaderT action
    (userInfo, opCtxMap, typeMap, fldMap, ordByCtx, insCtxMap, sqlGenCtx)
  either throwError return res
  where
    opCtxMap = _gOpCtxMap ctx
    typeMap = _gTypes ctx
    fldMap = _gFields ctx
    ordByCtx = _gOrdByCtx ctx
    insCtxMap = _gInsCtxMap ctx

getQueryOp
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> VQ.SelSet
  -> [G.VariableDefinition]
  -> m (LazyRespTx, Maybe EQ.ReusableQueryPlan)
getQueryOp gCtx sqlGenCtx userInfo fields varDefs =
  runE gCtx sqlGenCtx userInfo $ EQ.convertQuerySelSet varDefs fields

mutationRootName :: Text
mutationRootName = "mutation_root"

resolveMutSelSet
  :: ( MonadError QErr m
     , MonadReader r m
     , Has UserInfo r
     , Has OpCtxMap r
     , Has FieldMap r
     , Has OrdByCtx r
     , Has SQLGenCtx r
     , Has InsCtxMap r
     )
  => VQ.SelSet
  -> m LazyRespTx
resolveMutSelSet fields = do
  aliasedTxs <- forM (toList fields) $ \fld -> do
    fldRespTx <- case VQ._fName fld of
      "__typename" -> return $ return $ encJFromJValue mutationRootName
      _            -> liftTx <$> GR.mutFldToTx fld
    return (G.unName $ G.unAlias $ VQ._fAlias fld, fldRespTx)

  -- combines all transactions into a single transaction
  return $ toSingleTx aliasedTxs
  where
    -- A list of aliased transactions for eg
    -- [("f1", Tx r1), ("f2", Tx r2)]
    -- are converted into a single transaction as follows
    -- Tx {"f1": r1, "f2": r2}
    toSingleTx :: [(Text, LazyRespTx)] -> LazyRespTx
    toSingleTx aliasedTxs =
      fmap encJFromAssocList $
      forM aliasedTxs $ \(al, tx) -> (,) al <$> tx

getMutOp
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> VQ.SelSet
  -> m LazyRespTx
getMutOp ctx sqlGenCtx userInfo selSet =
  runE ctx sqlGenCtx userInfo $ resolveMutSelSet selSet

getSubsOpM
  :: ( MonadError QErr m
     , MonadReader r m
     , Has OpCtxMap r
     , Has FieldMap r
     , Has OrdByCtx r
     , Has SQLGenCtx r
     , Has UserInfo r
     , MonadIO m
     )
  => PGExecCtx
  -> GQLReqUnparsed
  -> [G.VariableDefinition]
  -> VQ.Field
  -> m (EL.LiveQueryOp, Maybe EL.SubsPlan)
getSubsOpM pgExecCtx req varDefs fld =
  case VQ._fName fld of
    "__typename" ->
      throwVE "you cannot create a subscription on '__typename' field"
    _            -> do
      astUnresolved <- GR.queryFldToPGAST fld
      EL.subsOpFromPGAST pgExecCtx req varDefs (VQ._fAlias fld, astUnresolved)

getSubsOp
  :: ( MonadError QErr m
     , MonadIO m
     )
  => PGExecCtx
  -> GCtx
  -> SQLGenCtx
  -> UserInfo
  -> GQLReqUnparsed
  -> [G.VariableDefinition]
  -> VQ.Field
  -> m (EL.LiveQueryOp, Maybe EL.SubsPlan)
getSubsOp pgExecCtx gCtx sqlGenCtx userInfo req varDefs fld =
  runE gCtx sqlGenCtx userInfo $ getSubsOpM pgExecCtx req varDefs fld

execRemoteGQ
  :: (MonadIO m, MonadError QErr m)
  => HTTP.Manager
  -> UserInfo
  -> [N.Header]
  -> RemoteSchemaInfo
  -> Either L.ByteString [Field]
  -> m (HttpResponse EncJSON)
execRemoteGQ manager userInfo reqHdrs remoteSchemaInfo bsOrField = do
  hdrs <- getHeadersFromConf hdrConf
  let confHdrs   = map (\(k, v) -> (CI.mk $ CS.cs k, CS.cs v)) hdrs
      clientHdrs = bool [] filteredHeaders fwdClientHdrs
      -- filter out duplicate headers
      -- priority: conf headers > resolved userinfo vars > client headers
      hdrMaps    = [ Map.fromList confHdrs
                   , Map.fromList userInfoToHdrs
                   , Map.fromList clientHdrs
                   ]
      finalHdrs  = foldr Map.union Map.empty hdrMaps
      options    = wreqOptions manager (Map.toList finalHdrs)

  jsonbytes <- case bsOrField of
    Right field -> do gqlReq <- fieldsToRequest field
                      let jsonbytes = encJToLBS (encJFromJValue gqlReq)
                      pure jsonbytes
    Left bytes -> pure bytes

  liftIO (putStrLn ("payload_to_server = " ++ L8.unpack jsonbytes))
  res  <- liftIO $ try $ Wreq.postWith options (show url) jsonbytes
  resp <- either httpThrow return res
  let cookieHdr = getCookieHdr (resp ^? Wreq.responseHeader "Set-Cookie")
      respHdrs  = Just $ mkRespHeaders cookieHdr
  return $ HttpResponse (encJFromLBS $ resp ^. Wreq.responseBody) respHdrs

  where
    (RemoteSchemaInfo url hdrConf fwdClientHdrs) = remoteSchemaInfo

    httpThrow :: (MonadError QErr m) => HTTP.HttpException -> m a
    httpThrow err = throw500 $ T.pack . show $ err

    userInfoToHdrs = map (\(k, v) -> (CI.mk $ CS.cs k, CS.cs v)) $
                     userInfoToList userInfo
    filteredHeaders = filterUserVars $ filterRequestHeaders reqHdrs

    filterUserVars hdrs =
      let txHdrs = map (\(n, v) -> (bsToTxt $ CI.original n, bsToTxt v)) hdrs
      in map (\(k, v) -> (CI.mk $ CS.cs k, CS.cs v)) $
         filter (not . isUserVar . fst) txHdrs

    getCookieHdr = maybe [] (\h -> [("Set-Cookie", h)])

    mkRespHeaders hdrs =
      map (\(k, v) -> Header (bsToTxt $ CI.original k, bsToTxt v)) hdrs

fieldsToRequest
  :: (MonadIO m, MonadError QErr m)
  => [VQ.Field]
  -> m GQLReqParsed
fieldsToRequest fields = do
  case traverse fieldToField fields of
    Right gfields ->
      pure
        (GQLReq
           { _grOperationName = Nothing
           , _grQuery =
               GQLExecDoc
                 [ G.ExecutableDefinitionOperation
                     (G.OperationDefinitionUnTyped (map G.SelectionField gfields))
                 ]
           , _grVariables = Nothing -- TODO: Put variables in here?
           })
    Left err -> throw500 ("While converting remote field: " <> err)

fieldToField :: VQ.Field -> Either Text G.Field
fieldToField field = do
  args <- traverse makeArgument (Map.toList (VQ._fArguments field))
  selections <- traverse fieldToField (VQ._fSelSet field)
  pure $ G.Field
    { _fAlias = Just (VQ._fAlias field)
    , _fName = VQ._fName field
    , _fArguments = args
    , _fDirectives = []
    , _fSelectionSet = fmap G.SelectionField (toList selections)
    }

makeArgument :: (G.Name, AnnInpVal) -> Either Text G.Argument
makeArgument (gname, annInpVal) =
  do v <- annInpValToValue annInpVal
     pure $ G.Argument {_aName = gname, _aValue = v}

annInpValToValue :: AnnInpVal -> Either Text G.Value
annInpValToValue = annGValueToValue . _aivValue

annGValueToValue :: AnnGValue -> Either Text G.Value
annGValueToValue =
  \case
    AGScalar _ty mv ->
      case mv of
        Nothing -> pure G.VNull
        Just pg -> pgcolvalueToGValue pg
    AGEnum _ mval ->
      case mval of
        Nothing -> pure G.VNull
        Just enumValue -> pure (G.VEnum enumValue)
    AGObject _ mobj ->
      case mobj of
        Nothing -> pure G.VNull
        Just obj -> do
          fields <-
            traverse
              (\(k, av) -> do
                 v <- annInpValToValue av
                 pure (G.ObjectFieldG {_ofName = k, _ofValue = v}))
              (OHM.toList obj)
          pure (G.VObject (G.ObjectValueG fields))
    AGArray _ mvs ->
      case mvs of
        Nothing -> pure G.VNull
        Just vs -> G.VList . G.ListValueG <$> traverse annInpValToValue vs

pgcolvalueToGValue :: PGColValue -> Either Text G.Value
pgcolvalueToGValue colVal = case colVal of
  PGValInteger i  -> pure $ G.VInt $ fromIntegral i
  PGValSmallInt i -> pure $ G.VInt $ fromIntegral i
  PGValBigInt i   -> pure $ G.VInt $ fromIntegral i
  PGValFloat f    -> pure $ G.VFloat $ realToFrac f
  PGValDouble d   -> pure $ G.VFloat $ realToFrac d
  -- TODO: Scientific is a danger zone; use its safe conv function.
  PGValNumeric sc -> pure $ G.VFloat $ realToFrac sc
  PGValBoolean b  -> pure $ G.VBoolean b
  PGValChar t     -> pure $ G.VString (G.StringValue (T.singleton t))
  PGValVarchar t  -> pure $ G.VString (G.StringValue t)
  PGValText t     -> pure $ G.VString (G.StringValue t)
  PGValDate d     -> pure $ G.VString $ G.StringValue $ T.pack $ showGregorian d
  PGValTimeStampTZ u -> pure $
    G.VString $ G.StringValue $   T.pack $ formatTime defaultTimeLocale "%FT%T%QZ" u
  PGValTimeTZ (ZonedTimeOfDay tod tz) -> pure $
    G.VString $ G.StringValue $   T.pack (show tod ++ timeZoneOffsetString tz)
  PGNull _ -> pure G.VNull
  PGValJSON {}    -> Left "PGValJSON: cannot convert"
  PGValJSONB {}  -> Left "PGValJSONB: cannot convert"
  PGValGeo {}    -> Left "PGValGeo: cannot convert"
  PGValUnknown t -> pure $ G.VString $ G.StringValue t
