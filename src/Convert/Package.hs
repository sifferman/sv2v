{-# LANGUAGE TupleSections #-}
{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - Conversion for packages and global declarations
 -
 - This conversion first makes a best-effort pass at resolving any simple
 - declaration ordering issues in the input. Many conversions require that
 - declarations precede their first usage.
 -
 - The main phase elaborates packages and resolves imported identifiers. An
 - identifier (perhaps implicitly) referring to `P::X` is rewritten to `P_X`.
 - This conversion assumes such renaming will not cause conflicts. The full
 - semantics of imports and exports are followed.
 -
 - Finally, because Verilog doesn't allow declarations to exist outside of
 - modules, declarations within packages and in the global scope are injected
 - into modules and interfaces as needed.
 -}

module Convert.Package
    ( convert
    , inject
    ) where

import Control.Monad.State.Strict
import Control.Monad.Writer.Strict
import Data.List (insert, intercalate)
import Data.Maybe (mapMaybe)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Convert.Scoper
import Convert.Traverse
import Language.SystemVerilog.AST

type Packages = Map.Map Identifier Package
type Package = (IdentStateMap, [PackageItem])
type Idents = Set.Set Identifier
type PIs = Map.Map Identifier PackageItem

convert :: [AST] -> [AST]
convert files =
    map (traverseDescriptions $ convertDescription pis) files'
    where
        (files', packages') = convertPackages files
        pis = Map.fromList $
            concatMap (concatMap (toPackageItems . makeLocal) . snd) $
            filter (not . Map.null . fst) $
            Map.elems packages'
        toPackageItems :: PackageItem -> [(Identifier, PackageItem)]
        toPackageItems item = map (, item) (piNames item)
        makeLocal :: PackageItem -> PackageItem
        makeLocal (Decl (Param _ t x e)) = Decl $ Param Localparam t x e
        makeLocal (Decl (ParamType _ x t)) = Decl $ ParamType Localparam x t
        makeLocal other = other

-- utility for inserting package items into a set of module items as needed
inject :: [PackageItem] -> [ModuleItem] -> [ModuleItem]
inject packageItems items =
    addItems localPIs Set.empty (map addUsedPIs items)
    where
        localPIs = Map.fromList $ concatMap toPIElem packageItems
        toPIElem :: PackageItem -> [(Identifier, PackageItem)]
        toPIElem item = map (, item) (piNames item)

-- collect packages and global package items
collectPackageM :: Description -> Writer (Packages, [PackageItem]) ()
collectPackageM (PackageItem item) =
    when (not $ null $ piNames item) $
        tell (Map.empty, [item])
collectPackageM (Package _ name items) =
    tell (Map.singleton name (Map.empty, items), [])
collectPackageM _ = return ()

-- elaborate all packages and their usages
convertPackages :: [AST] -> ([AST], Packages)
convertPackages files =
    (files', packages')
    where
        (files', ([], packages')) = runState op ([], packages)
        op = mapM (traverseDescriptionsM traverseDescriptionM) files
        packages = Map.insert "" (Map.empty, globalItems) realPackages
        (realPackages, globalItems) =
            execWriter $ mapM (collectDescriptionsM collectPackageM) files

type PackagesState = State ([Identifier], Packages)

traverseDescriptionM :: Description -> PackagesState Description
traverseDescriptionM (PackageItem item) = do
    return $ PackageItem $ case piNames item of
        [] -> item
        idents -> Decl $ CommentDecl $ "removed " ++ show idents
traverseDescriptionM (Package _ name _) =
    return $ PackageItem $ Decl $ CommentDecl $ "removed package " ++ show name
traverseDescriptionM (Part attrs extern kw liftetime name ports items) = do
    (_, items') <- processItems name "" items
    return $ Part attrs extern kw liftetime name ports items'

data IdentState
    = Available [Identifier]
    | Imported Identifier
    | Declared
    deriving Eq

isImported :: IdentState -> Bool
isImported Imported{} = True
isImported _ = False

isDeclared :: IdentState -> Bool
isDeclared Declared{} = True
isDeclared _ = False

type IdentStateMap = Map.Map Identifier IdentState
type Scope = ScoperT IdentState PackagesState

-- produce the partial mapping for a particular export and ensure its validity
resolveExport
    :: IdentStateMap -> Identifier -> Identifier -> PackagesState IdentStateMap
resolveExport mapping "" "" =
    return $ Map.filter isImported mapping
resolveExport mapping pkg "" =
    fmap (Map.mapMaybeWithKey checkExport . fst) (findPackage pkg)
    where
        checkExport :: Identifier -> IdentState -> Maybe IdentState
        checkExport ident exportedIdentState =
            if localIdentState == expectedIdentState
                then localIdentState
                else Nothing
            where
                localIdentState = Map.lookup ident mapping
                expectedIdentState = Just $ Imported $
                    toRootPackage pkg exportedIdentState
resolveExport mapping pkg ident =
    case Map.lookup ident mapping of
        Just (Imported importedPkg) -> do
            exportedPkg <- resolveRootPackage pkg ident
            if importedPkg == exportedPkg
                then return $ Map.singleton ident $ Imported importedPkg
                else error $ "export of " ++ pkg ++ "::" ++ ident
                        ++ " differs from import of " ++ importedPkg
                        ++ "::" ++ ident
        _ -> error $ "export of " ++ pkg ++ "::" ++ ident
                ++ ", but " ++ ident ++ " was never imported"

-- lookup the state of the identifier only within the current scope
lookupLocalIdentState :: Identifier -> Scope (Maybe IdentState)
lookupLocalIdentState =
    fmap (fmap thd3) . lookupLocalIdentM
    where thd3 (_, _, c) = c

-- make a particular identifier within a package available for import
wildcardImport :: Identifier -> Identifier -> Scope ()
wildcardImport pkg ident = do
    rootPkg <- lift $ resolveRootPackage pkg ident
    maybeIdentState <- lookupLocalIdentState ident
    insertElem ident $
        case maybeIdentState of
            Nothing -> Available [rootPkg]
            Just Declared -> Declared
            Just (Imported existingRootPkg) -> Imported existingRootPkg
            Just (Available rootPkgs) ->
                if elem rootPkg rootPkgs
                    then Available rootPkgs
                    else Available $ insert rootPkg rootPkgs

-- make all exported identifiers within a package available for import
wildcardImports :: Identifier -> Scope ()
wildcardImports pkg = do
    (exports, _) <- lift $ findPackage pkg
    _ <- mapM (wildcardImport pkg) (Map.keys exports)
    return ()

-- resolve and store an explicit (non-wildcard) import
explicitImport :: Identifier -> Identifier -> Scope ()
explicitImport pkg ident = do
    rootPkg <- lift $ resolveRootPackage pkg ident
    maybeIdentState <- lookupLocalIdentState ident
    insertElem ident $
        case maybeIdentState of
            Nothing -> Imported rootPkg
            Just Declared ->
                error $ "import of " ++ pkg ++ "::" ++ ident
                    ++ " conflicts with prior declaration of " ++ ident
            Just Available{} -> Imported rootPkg
            Just (Imported otherPkg) ->
                if otherPkg == rootPkg
                    then Imported rootPkg
                    else error $ "import of " ++ pkg ++ "::" ++ ident
                            ++ " conflicts with prior import of "
                            ++ otherPkg ++ "::" ++ ident

-- main logic responsible for translating packages, resolving imports and
-- exports, and rewriting identifiers referring to package declarations
processItems :: Identifier -> Identifier -> [ModuleItem]
    -> PackagesState (IdentStateMap, [ModuleItem])
processItems topName packageName moduleItems = do
    (moduleItems', scopes) <- runScoperT
        traverseDeclM traverseModuleItemM traverseGenItemM traverseStmtM
        topName (reorderItems moduleItems)
    let rawIdents = extractMapping scopes
    externalIdentMaps <- mapM (resolveExportMI rawIdents) moduleItems
    let externalIdents = Map.unions externalIdentMaps
    let declaredIdents = Map.filter isDeclared rawIdents
    let exports = Map.union declaredIdents externalIdents
    let exports' = if null packageName
                    then rawIdents
                    else exports
    seq exports return (exports', moduleItems')
    where
        -- produces partial mappings of exported identifiers, while also
        -- checking the validity of the exports
        resolveExportMI :: IdentStateMap -> ModuleItem -> PackagesState IdentStateMap
        resolveExportMI mapping (MIPackageItem (item @ (Export pkg ident))) =
            if null packageName
                then error $ "invalid " ++ (init $ show item)
                        ++ " outside of package"
                else resolveExport mapping pkg ident
        resolveExportMI _ _ = return Map.empty

        -- declare an identifier, prefixing it if within a package
        prefixIdent :: Identifier -> Scope Identifier
        prefixIdent x = do
            inProcedure <- withinProcedureM
            maybeIdentState <- lookupLocalIdentState x
            case maybeIdentState of
                Just (Imported rootPkg) -> error $ "declaration of " ++ x
                    ++ " conflicts with prior import of " ++ rootPkg
                    ++ "::" ++ x
                _ -> do
                    insertElem x Declared
                    if inProcedure || null packageName
                        then return x
                        else return $ packageName ++ '_' : x

        -- check the global scope for declarations or imports
        resolveGlobalIdent :: Identifier -> Scope Identifier
        resolveGlobalIdent x = do
            (exports, _) <- lift $ findPackage ""
            case Map.lookup x exports of
                Nothing -> return x
                Just identState -> do
                    -- inject the exact state outside of the module scope,
                    -- allowing wildcard imports to be handled correctly
                    insertElem [Access x Nil] identState
                    resolveIdent x

        -- remap an identifier if needed based on declarations, explicit
        -- imports, or names available for import
        resolveIdent :: Identifier -> Scope Identifier
        resolveIdent x = do
            details <- lookupElemM x
            case details of
                Nothing ->
                    if null topName
                        then return x
                        else resolveGlobalIdent x
                Just ([_, _], _, Declared) ->
                    if null packageName
                        then return x
                        else return $ packageName ++ '_' : x
                Just (_, _, Declared) -> return x
                Just (_, _, Imported rootPkg) ->
                    return $ rootPkg ++ '_' : x
                Just (accesses, _, Available [rootPkg]) -> do
                    insertElem accesses $ Imported rootPkg
                    return $ rootPkg ++ '_' : x
                Just (_, _, Available rootPkgs) ->
                    error $ "identifier " ++ show x
                        ++ " ambiguously refers to the definitions in any of "
                        ++ intercalate ", " rootPkgs

        traversePackageItemM :: PackageItem -> Scope PackageItem
        traversePackageItemM (orig @ (Import pkg ident)) = do
            if null ident
                then wildcardImports pkg
                else explicitImport pkg ident
            return $ Decl $ CommentDecl $ "removed " ++ show orig
        traversePackageItemM (orig @ (Export pkg ident)) = do
            () <- when (not (null pkg || null ident)) $ do
                localName <- resolveIdent ident
                rootPkg <- lift $ resolveRootPackage pkg ident
                localName `seq` rootPkg `seq` return ()
            return $ Decl $ CommentDecl $ "removed " ++ show orig
        traversePackageItemM other = return other

        traverseDeclM :: Decl -> Scope Decl
        traverseDeclM decl = do
            decl' <- case decl of
                Variable d t x a e -> declHelp x $ \x' -> Variable d t x' a e
                Param    p t x   e -> declHelp x $ \x' -> Param    p t x'   e
                ParamType  p x   t -> declHelp x $ \x' -> ParamType  p x'   t
                CommentDecl c -> return $ CommentDecl c
            traverseDeclTypesM traverseTypeM decl' >>=
                traverseDeclExprsM traverseExprM
            where declHelp x f = prefixIdent x >>= return . f

        traverseTypeM :: Type -> Scope Type
        traverseTypeM (PSAlias p x rs) = do
            x' <- lift $ resolvePSIdent p x
            return $ Alias x' rs
        traverseTypeM (Alias x rs) =
            resolveIdent x >>= \x' -> return $ Alias x' rs
        traverseTypeM (Enum t enumItems rs) = do
            enumItems' <- mapM prefixEnumItem enumItems
            return $ Enum t enumItems' rs
            where prefixEnumItem (x, e) = prefixIdent x >>= \x' -> return (x', e)
        traverseTypeM other = traverseSinglyNestedTypesM traverseTypeM other

        traverseExprM (PSIdent p x) = do
            x' <- lift $ resolvePSIdent p x
            return $ Ident x'
        traverseExprM (Ident x) = resolveIdent x >>= return . Ident
        traverseExprM other = traverseSinglyNestedExprsM traverseExprM other
        traverseLHSM (LHSIdent x) = resolveIdent x >>= return . LHSIdent
        traverseLHSM other = traverseSinglyNestedLHSsM traverseLHSM other

        traverseGenItemM = traverseGenItemExprsM traverseExprM
        traverseModuleItemM (MIPackageItem item) = do
            item' <- traversePackageItemM item
            return $ MIPackageItem item'
        traverseModuleItemM other =
            traverseModuleItemM' other
        traverseModuleItemM' =
            traverseTypesM traverseTypeM >=>
            traverseExprsM traverseExprM >=>
            traverseLHSsM  traverseLHSM
        traverseStmtM =
            traverseStmtExprsM traverseExprM >=>
            traverseStmtLHSsM  traverseLHSM

-- locate a package by name, processing its contents if necessary
findPackage :: Identifier -> PackagesState Package
findPackage packageName = do
    (stack, packages) <- get
    let maybePackage = Map.lookup packageName packages
    assertMsg (maybePackage /= Nothing) $
        "could not find package " ++ show packageName
    -- because this conversion doesn't enforce declaration ordering of packages,
    -- it must check for dependency loops to avoid infinite recursion
    let first : rest = reverse $ packageName : stack
    assertMsg (not $ elem packageName stack) $
        "package dependency loop: " ++ show first ++ " depends on "
            ++ intercalate ", which depends on " (map show rest)
    let Just (package @ (exports, _))= maybePackage
    if Map.null exports
        then do
            -- process and resolve this package
            put (packageName : stack, packages)
            package' <- processPackage packageName $ snd package
            packages' <- gets snd
            put (stack, Map.insert packageName package' packages')
            return package'
        else return package

-- helper for elaborating a package when it is first referenced
processPackage :: Identifier -> [PackageItem] -> PackagesState Package
processPackage packageName packageItems = do
    (exports, moduleItems') <- processItems packageName packageName wrapped
    let packageItems' = map unwrap moduleItems'
    let package' = (exports, packageItems')
    return package'
    where
        wrapped = map wrap packageItems
        wrap :: PackageItem -> ModuleItem
        wrap = MIPackageItem
        unwrap :: ModuleItem -> PackageItem
        unwrap packageItem = item
            where MIPackageItem item = packageItem

-- resolve a package scoped identifier to its unique global name
resolvePSIdent :: Identifier -> Identifier -> PackagesState Identifier
resolvePSIdent packageName itemName = do
    rootPkg <- resolveRootPackage packageName itemName
    return $ rootPkg ++ '_' : itemName

-- determines the root package contained the given package scoped identifier
resolveRootPackage :: Identifier -> Identifier -> PackagesState Identifier
resolveRootPackage packageName itemName = do
    (exports, _) <- findPackage packageName
    let maybeIdentState = Map.lookup itemName exports
    assertMsg (maybeIdentState /= Nothing) $
        "could not find " ++ show itemName ++ " in package " ++ show packageName
    let Just identState = maybeIdentState
    return $ toRootPackage packageName identState

-- errors with the given message when the check is false
assertMsg :: Monad m => Bool -> String -> m ()
assertMsg check msg = when (not check) $ error msg

-- helper for taking an ident which is either declared or exported form a
-- package and determine its true root source package
toRootPackage :: Identifier -> IdentState -> Identifier
toRootPackage sourcePackage identState =
    if identState == Declared
        then sourcePackage
        else rootPackage
    where Imported rootPackage = identState

-- nests packages items missing from modules
convertDescription :: PIs -> Description -> Description
convertDescription pis (orig @ Part{}) =
    if Map.null pis
        then orig
        else Part attrs extern kw lifetime name ports items'
    where
        Part attrs extern kw lifetime name ports items = orig
        items' = addItems pis Set.empty (map addUsedPIs items)
convertDescription _ other = other

-- attempt to fix simple declaration order issues
reorderItems :: [ModuleItem] -> [ModuleItem]
reorderItems items =
    addItems localPIs Set.empty $ map addUsedPIs $
        map (traverseGenItems $ traverseNestedGenItems reorderGenItem) items
    where
        localPIs = Map.fromList $ concat $ mapMaybe toPIElem items
        toPIElem :: ModuleItem -> Maybe [(Identifier, PackageItem)]
        toPIElem (MIPackageItem item) = Just $ map (, item) (piNames item)
        toPIElem _ = Nothing

-- attempt to declaration order issues within generate blocks
reorderGenItem :: GenItem -> GenItem
reorderGenItem (GenBlock name genItems) =
    GenBlock name $ map unwrap $ reorderItems $ map wrap genItems
    where
        wrap :: GenItem -> ModuleItem
        wrap (GenModuleItem item) = item
        wrap item = Generate [item]
        unwrap :: ModuleItem -> GenItem
        unwrap (Generate [item]) = item
        unwrap item = GenModuleItem item
reorderGenItem item = item

-- iteratively inserts missing package items exactly where they are needed
addItems :: PIs -> Idents -> [(ModuleItem, Idents)] -> [ModuleItem]
addItems pis existingPIs ((item, usedPIs) : items) =
    if not $ Set.disjoint existingPIs thisPI then
        -- this item was re-imported earlier in the module
        addItems pis existingPIs items
    else if null itemsToAdd then
        -- this item has no additional dependencies
        item : addItems pis (Set.union existingPIs thisPI) items
    else
        -- this item has at least one un-met dependency
        addItems pis existingPIs (addUsedPIs chosen : (item, usedPIs) : items)
    where
        thisPI = case item of
            MIPackageItem packageItem ->
                Set.fromList $ piNames packageItem
            _ -> Set.empty
        neededPIs = Set.difference (Set.difference usedPIs existingPIs) thisPI
        itemsToAdd = map MIPackageItem $ Map.elems $
            Map.restrictKeys pis neededPIs
        chosen = head itemsToAdd
addItems _ _ [] = []

-- augment a module item with the set of identifiers it uses
addUsedPIs :: ModuleItem -> (ModuleItem, Idents)
addUsedPIs item =
    (item, usedPIs)
    where
        usedPIs = execWriter $ evalScoperT
            writeDeclIdents writeModuleItemIdents writeGenItemIdents writeStmtIdents
            "" [item]

type IdentWriter = ScoperT () (Writer Idents)

writeDeclIdents :: Decl -> IdentWriter Decl
writeDeclIdents decl = do
    case decl of
        Variable _ _ x _ _ -> insertElem x ()
        Param    _ _ x   _ -> insertElem x ()
        ParamType  _ x   _ -> insertElem x ()
        CommentDecl{} -> return ()
    traverseDeclIdentsM writeIdent decl

writeModuleItemIdents :: ModuleItem -> IdentWriter ModuleItem
writeModuleItemIdents = traverseIdentsM writeIdent

writeGenItemIdents :: GenItem -> IdentWriter GenItem
writeGenItemIdents =
    traverseGenItemExprsM $ traverseExprIdentsM writeIdent

writeStmtIdents :: Stmt -> IdentWriter Stmt
writeStmtIdents = traverseStmtIdentsM writeIdent

writeIdent :: Identifier -> IdentWriter Identifier
writeIdent x = do
    details <- lookupElemM x
    when (details == Nothing) $ tell (Set.singleton x)
    return x

-- visits all identifiers in a module item
traverseIdentsM :: Monad m => MapperM m Identifier -> MapperM m ModuleItem
traverseIdentsM identMapper = traverseNodesM
    (traverseExprIdentsM identMapper)
    (traverseDeclIdentsM identMapper)
    (traverseTypeIdentsM identMapper)
    (traverseLHSIdentsM  identMapper)
    (traverseStmtIdentsM identMapper)

-- visits all identifiers in an expression
traverseExprIdentsM :: Monad m => MapperM m Identifier -> MapperM m Expr
traverseExprIdentsM identMapper = fullMapper
    where
        fullMapper = exprMapper >=> traverseSinglyNestedExprsM fullMapper
        exprMapper (Call (Ident x) args) =
            identMapper x >>= \x' -> return $ Call (Ident x') args
        exprMapper (Ident x) = identMapper x >>= return . Ident
        exprMapper other = return other

-- visits all identifiers in a type
traverseTypeIdentsM :: Monad m => MapperM m Identifier -> MapperM m Type
traverseTypeIdentsM identMapper = fullMapper
    where
        fullMapper = typeMapper
            >=> traverseTypeExprsM (traverseExprIdentsM identMapper)
            >=> traverseSinglyNestedTypesM fullMapper
        typeMapper (Alias       x t) = aliasHelper (Alias      ) x t
        typeMapper (PSAlias p   x t) = aliasHelper (PSAlias p  ) x t
        typeMapper (CSAlias c p x t) = aliasHelper (CSAlias c p) x t
        typeMapper other = return other
        aliasHelper constructor x t =
            identMapper x >>= \x' -> return $ constructor x' t

-- visits all identifiers in an LHS
traverseLHSIdentsM :: Monad m => MapperM m Identifier -> MapperM m LHS
traverseLHSIdentsM identMapper = fullMapper
    where
        fullMapper = lhsMapper
            >=> traverseLHSExprsM (traverseExprIdentsM identMapper)
            >=> traverseSinglyNestedLHSsM fullMapper
        lhsMapper (LHSIdent x) = identMapper x >>= return . LHSIdent
        lhsMapper other = return other

-- visits all identifiers in a statement
traverseStmtIdentsM :: Monad m => MapperM m Identifier -> MapperM m Stmt
traverseStmtIdentsM identMapper = fullMapper
    where
        fullMapper = stmtMapper
            >=> traverseStmtExprsM (traverseExprIdentsM identMapper)
            >=> traverseStmtLHSsM  (traverseLHSIdentsM  identMapper)
        stmtMapper (Subroutine (Ident x) args) =
            identMapper x >>= \x' -> return $ Subroutine (Ident x') args
        stmtMapper other = return other

-- visits all identifiers in a declaration
traverseDeclIdentsM :: Monad m => MapperM m Identifier -> MapperM m Decl
traverseDeclIdentsM identMapper =
    traverseDeclExprsM (traverseExprIdentsM identMapper) >=>
    traverseDeclTypesM (traverseTypeIdentsM identMapper)

-- returns any names defined by a package item
piNames :: PackageItem -> [Identifier]
piNames (Decl (ParamType _ ident (Enum _ enumItems _))) =
    ident : map fst enumItems
piNames (Function _ _ ident _ _) = [ident]
piNames (Task     _   ident _ _) = [ident]
piNames (Decl (Variable _ _ ident _ _)) = [ident]
piNames (Decl (Param    _ _ ident   _)) = [ident]
piNames (Decl (ParamType  _ ident   _)) = [ident]
piNames (Decl (CommentDecl          _)) = []
piNames (Import x y) = [show $ Import x y]
piNames (Export x y) = [show $ Export x y]
piNames (Directive _) = []
