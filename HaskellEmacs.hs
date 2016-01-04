{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE OverloadedStrings    #-}

module Main where
{--<<import>>--}
import           Control.Applicative              (optional, (<$>), (<*>))
import           Control.Arrow                    hiding (app)
import           Control.Concurrent
import           Control.Monad                    (forever)
import           Control.Monad.Trans.Reader
import           Control.Parallel.Strategies
import           Data.AttoLisp
import qualified Data.Attoparsec.ByteString.Char8 as AC
import qualified Data.Attoparsec.ByteString.Lazy  as A
import qualified Data.ByteString.Lazy.Char8       as B hiding (length)
import qualified Data.ByteString.Lazy.UTF8        as B (length)
import qualified Data.Map                         as M
import           Data.Maybe
import           Data.Monoid                      ((<>))
import           Data.Text                        (Text)
import qualified Data.Text                        as T
import           Foreign.Emacs.Internal
import           Language.Haskell.Exts            hiding (List, String, Symbol,
                                                   name, sym)
import           Language.Haskell.Exts.SrcLoc
import qualified Language.Haskell.Exts.Syntax     as S (Name (Ident, Symbol))
import           System.IO                        (hFlush, stdout)

class Arity f where
  arity :: f -> Int

instance Arity x where
  arity _ = 0

instance Arity f => Arity ((->) a f) where
  arity f = 1 + arity (f undefined)

data Instruction = EmacsToHaskell Lisp
                 | HaskellToEmacs B.ByteString
                 | StartDialog (Emacs Lisp) Int

{-@ StartDialog :: Emacs Lisp -> Nat -> Instruction @-}

-- | Watch for commands and dispatch them in a seperate fork.
main :: IO ()
main = do
  printer <- newChan
  getter  <- newEmptyMVar
  lock    <- newMVar ()
  _       <- forkIO . forever $ readChan printer >>= B.putStr >> hFlush stdout
  is      <- fullParse <$> B.getContents
  mapM_ (forkIO . runInstruction lock getter printer) is

runInstruction :: MVar () -> MVar Lisp -> Chan B.ByteString -> Instruction -> IO ()
runInstruction _ g _ (EmacsToHaskell ls)                 = putMVar g   $! ls
runInstruction _ _ p (HaskellToEmacs msg)                = writeChan p $! msg
runInstruction l g p (StartDialog (EmacsInternal rdr) n) = withMVar l $ \_ -> do
  x <- runReaderT rdr (g, p)
  writeChan p . formatResult n $ Success x

-- | Recursively evaluate a lisp in parallel, using functions defined
-- by the user (see documentation of the emacs function `haskell-emacs-init').
{-@ Lazy traverseLisp @-}
traverseLisp :: Either (Emacs Lisp) Lisp -> Result (Either (Emacs Lisp) Lisp)
traverseLisp l = case l of
  Right (List (Symbol x:xs)) -> sym (T.filter (/='\\') x) xs
  Right (List xs)            -> Right . List <$> evl xs
  Right (Symbol "nil")       -> Success $ Right nil
  _                          -> Success l
  where {-@ assume evl :: xs:[Lisp] -> Result {v:[Lisp] | len xs == len v} @-}
        evl      = (>>= noNest) . sequence . parMap rdeepseq (traverseLisp . Right)
        sym x xs = maybe (Right . List . (Symbol x:) <$> evl xs)
                         (=<< (if length xs == 1 then head else List) <$> evl xs)
                         $ M.lookup x dispatcher
        noNest   = either (const (Error "Emacs monad isn't nestable."))
                          Success . sequence

-- | Takes a stream of instructions and returns lazy list of
-- results.
{-@ Lazy fullParse @-}
fullParse :: B.ByteString -> [Instruction]
fullParse a = case parseInput a of A.Done a' b -> b : fullParse a'
                                   A.Fail {}   -> []

-- | Parse an instruction and stamp the number of the instruction into
-- the result.
parseInput :: B.ByteString -> A.Result Instruction
parseInput = A.parse $ do
  i          <- A.option 0 AC.decimal
  isInternal <- isJust <$> optional "|"
  l          <- lisp
  return $ if isInternal
    then EmacsToHaskell l
    else case traverseLisp $ Right l of
      Success (Left x)  -> StartDialog x i
      Success (Right x) -> HaskellToEmacs . formatResult i $ Success x
      Error x           -> HaskellToEmacs . formatResult i $ Error x

-- | Scrape the documentation of haskell functions to serve it in emacs.
{-@ getDocumentation :: x:[Text] -> Text -> {v:[Text] | len x == len v} @-}
getDocumentation :: [Text] -> Text -> [Text]
getDocumentation funs code =
  map ( \f -> T.unlines . (++) (filter (T.isPrefixOf (f <> " ::")) ls ++ [""])
      . reverse
      . map (T.dropWhile (`elem` ("- |" :: String)))
      . takeWhile (T.isPrefixOf "-- ")
      . reverse
      $ takeWhile (not . T.isPrefixOf (f <> " ")) ls
      ) funs
  where ls = T.lines code

{-@ formatResult :: Nat -> Result Lisp -> B.ByteString @-}
formatResult :: Int -> Result Lisp -> B.ByteString
formatResult i l = f $ case l of
      Success s -> (Just $ num i, encode s)
      Error s   -> (Nothing     , errorE s)
  where f (procNum, t) = encList (num (B.length t):maybeToList procNum) <> t
        errorE msg     = encList [Symbol "error", String $ T.pack msg]
        encList        = encode . List
        num            = Number . fromIntegral

-- | Map of available functions which get transformed to work on lisp.
dispatcher :: M.Map Text (Lisp -> Result (Either (Emacs Lisp) Lisp))
dispatcher = M.fromList $
  [ ("arityFormat", transform arityFormat . normalize)
  , ("allExports",  transform allExports)
  , ("arityList",   transform $ \() -> toDispatcher arityList)
  , ("formatCode",  transform $ uncurry formatCode)
  , ("getDocumentation", transform $ uncurry getDocumentation)
  ] ++ []{--<<export>>--}

-- | Transform a curried function to a function which receives and
-- returns lisp forms.
transform :: (FromLisp a, ToEmacs b) => (a -> b) -> Lisp -> Result (Either (Emacs Lisp) Lisp)
transform = (. fromLisp) . fmap . (toEmacs .)

-- | Prevent bad input for the bootstrap.
normalize :: Lisp -> Lisp
normalize l@(List _)      = l
normalize l@(DotList _ _) = l
normalize a               = List [a]

-- | Takes tuples of function names and their arities and returns
-- haskell source code which gets spliced back into a module.
toDispatcher :: [(String, Int)] -> (String, [String])
toDispatcher = ("++"++) . prettyPrint . listE . map fun
               &&& map (filter (\x -> x/=',' && x/='\n')
               . prettyPrint . pvarTuple . genNames "x" . snd)
  where fun (f,n) = tuple [strE f, app (function "transform")
                          $ lamE noLoc [pvarTuple $ genNames "x" n]
                          (appFun (function f) . map var $ genNames "x" n)]

-- | List of functions and their arities (filled by emacs).
arityList :: [(String, Int)]
arityList = []{--<<arity>>--}

-- | Splice user functions into the haskell module.
formatCode :: (Text, Text, Text) -> Text -> Text
formatCode (imports, exports, arities) = inject "arity"  arities
                                       . inject "export" exports
                                       . inject "import" imports
  where inject s = T.replace ("{--<<" <> s <> ">>--}")

-- | Import statement of all modules and all their qualified functions.
allExports :: [String] -> Either String (String, [String])
allExports = (qualify . filter ((&&) <$> hasFunctions <*> isLibrary) <$>)
             .  mapM exportsGet
  where qualify ys   = ( unlines [prettyPrint $ ImportDecl noLoc q
                                                True
                                                False
                                                False
                                                Nothing
                                                Nothing
                                                Nothing | (q,_) <- ys]
                       , [prettyPrint $ qvar q n | (q,ns) <- ys, n <- ns])
        isLibrary    = (/=ModuleName "Main") . fst
        hasFunctions = not . null . snd

-- | List of haskell functions which get querried for their arity.
arityFormat :: [String] -> String
arityFormat = ("++"++) . prettyPrint
              . listE . map (\x -> tuple [strE x, app (function "arity")
                                                      (function x)])

-- | Retrieve the name and a list of exported functions of a haskell module.
-- It should use 'parseFileContents' to take pragmas into account.
exportsGet :: String -> Either String (ModuleName, [Name])
exportsGet content = case parseSrc of
  ParseOk (Module _ name _ _ header _ decls)
    -> Right . (,) name $ maybe (exportsFromDecls decls)
                                 exportsFromHeader header
  ParseFailed _ msg -> Left msg
  where parseSrc = parseFileContentsWithMode
                     defaultParseMode {fixities = Nothing}
                     content

exportsFromDecls :: [Decl] -> [Name]
exportsFromDecls = mapMaybe declarationNames

declarationNames :: Decl -> Maybe Name
declarationNames (FunBind (Match _ name _ _ _ _ : _)) = Just name
declarationNames (PatBind _ (PVar name) _ _)          = Just name
declarationNames _                                    = Nothing

-- | Extract the unqualified function names from an ExportSpec.
exportsFromHeader :: [ExportSpec] -> [Name]
exportsFromHeader = mapMaybe exportFunction

fromName :: Name -> String
fromName (S.Symbol str) = str
fromName (S.Ident  str) = str

exportFunction :: ExportSpec -> Maybe Name
exportFunction (EVar qname)      = unQualifiedName qname
exportFunction (EModuleContents _) = Nothing
exportFunction _                   = Nothing

unQualifiedName :: QName -> Maybe Name
unQualifiedName (Qual _ name) = Just name
unQualifiedName (UnQual name) = Just name
unQualifiedName _             = Nothing
