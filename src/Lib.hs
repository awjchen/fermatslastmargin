{-# LANGUAGE ApplicativeDo         #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE UndecidableInstances  #-}
module Lib where

-- import           Config
import           Config.Schema
-- import           Config.Schema.Load
import           Control.Monad         (filterM, join)
import           Data.Aeson            (FromJSON, ToJSON, decodeStrict)
import           Data.Aeson.Text       (encodeToLazyText)
import qualified Data.ByteString       as BS
import qualified Data.Map.Strict       as M
import           Data.Maybe            (catMaybes, isJust)
import           Data.Text             (Text, pack)
import qualified Data.Text             as T
import           Data.Text.Encoding    (decodeUtf8)
import qualified Data.Text.Lazy        as TL
import           Data.Text.Lazy.IO     as I
import           Data.Time.Calendar    (Day)
import           GHC.Generics
import           Lucid
import           System.Directory
import           System.Exit           (ExitCode)
import           System.FilePath       (combine, splitFileName)
import           System.FilePath       ((</>))
import           System.FilePath.Find  (always, fileName, find, (~~?))
import           System.FilePath.Manip (renameWith)
import           System.Process        (StdStream (..), close_fds,
                                        createProcess, cwd, proc, std_err,
                                        std_in, std_out, waitForProcess)
import           Text.Read
import           Web.Scotty            (Param)

-- | Map from DOI to Paper
type FLMState = M.Map Text Paper -- local user state

-- | Map from friend name to FLMState
type FriendState = M.Map Text FLMState

data Paper = Paper {
      uid       :: Text -- usually DOI
    , author    :: Text -- really needs to be [Text] at some point
    , published :: Day -- unpublished or pre-prints? (Maybe Day) instead?
    , title     :: Text
    , notes     :: ![Annotation]
    } deriving (Show, Generic, ToJSON, FromJSON)

data Annotation = Annotation {
      content    :: Text
    , pageNumber :: Int -- if this ever exceeds a 64 bit Int, something is very wrong
    , paperuid   :: Text -- this makes life much easier
    } deriving (Show, Generic, ToJSON, FromJSON)

-- read and save state
maybeGetPage pageNum anns = lookup pageNum annPairs
    where annPairs = zip (pageNumber <$> anns) (content <$> anns)

maybeGetAnnotation pageNum anns = lookup pageNum annPairs
    where annPairs = zip (pageNumber <$> anns) anns

upsertAnnotation :: Annotation -> [Annotation] -> [Annotation]
upsertAnnotation a@(Annotation c pnum puid) oldAnns = if doesExist then replaceAnnotation pnum c oldAnns else a:oldAnns
    where doesExist = isJust $ maybeGetPage pnum oldAnns


replaceAnnotation :: Int -> Text -> [Annotation] -> [Annotation]
replaceAnnotation i content [] = []
replaceAnnotation i content (a@(Annotation c p u):anns) = if p == i then (Annotation content p u) : anns else a : replaceAnnotation i content anns

-- | read the names of the directories in the config directory
readState :: FilePath -> IO FLMState
readState fp = do
  allfiles <- listDirectory fp
  uids <- filterDirectory $ fmap (fp </>) allfiles -- put dirname in front
  ps <- sequence $ readPaper <$> uids
  let ps' = catMaybes ps -- drop the Paper values that failed to decode
      -- TODO should I be using dir names? if I use uid from Paper elsewhere, use that instead! TODO
  return $ M.fromList $ zip (uid <$> ps') ps' -- set the unique ID as the key, the Paper as the value

-- | filepath should be the FULL path to the user dir, so either localuser or a friendname
writeState :: FilePath -> FLMState -> IO ()
writeState fp flms = do
  -- M.Map Text Paper , dirname / doi -> Paper
  _ <- createDirectoryIfMissing True fp -- create friend/user dir if needed
  print $ "fp is " <> fp <> " and FLMState is " <> show flms
  mapM_ (writePaper fp) (M.elems flms)

-- | given a directory for a paper, read that json file into a Paper value
readPaper :: FilePath -> IO (Maybe Paper)
readPaper fp = do
  f <- findPaper fp "paper.json"
  bs <- BS.readFile (head f) -- XXX this gonna be a problem at some point XXX
  pure $ decodeStrict bs -- is this right? do I need this pure? can I concat it with the previous line?

-- | assume the dir given is the *USER* directory where all papers have their own directory
-- | arguments will be something like "~/.fermatslastmargin/localuser" and "10.4204/EPTCS.275.6"
-- | or perhaps "~/.fermatslastmargin/friends/pigworker" "10.4204/EPTCS.275.6"
-- | forward slash is not allowed in any filenames, so we substitute underscore _
writePaper :: FilePath -> Paper -> IO FilePath
writePaper fp p = do
  let fullDir = fp </> (T.unpack $ uid p)
  _ <- createDirectoryIfMissing True fullDir
  I.writeFile (fullDir </> "paper.json") (encodeToLazyText p)
  return fullDir

-- | given the friends dir, load FLM state from each of those dirs
readFriendState :: FilePath -> IO FriendState
readFriendState fp = do
  friendNames <- listDirectory fp
  friendDirs <- filterDirectoryPair $ zip (fmap (fp </>) friendNames) friendNames
  friendStates <- mapM readState (fst <$> friendDirs)
  pure $ M.fromList (zip (T.pack <$> friendNames) friendStates)

-- what's wrong with the dang parser here?
filterDirectory :: [FilePath] -> IO [FilePath]
filterDirectory = filterM doesDirectoryExist

-- | [("/home/shae","shae"),("/home/plato","plato")] -> [("/home/shae","shae")]
-- I don't much like this, but I need it anyway
filterDirectoryPair :: [(FilePath, FilePath)] -> IO [(FilePath, FilePath)]
filterDirectoryPair = filterM (\(a,b) -> doesDirectoryExist a)

filterFile :: [FilePath] -> IO [FilePath]
filterFile = filterM doesFileExist

-- well this won't work anymore, will it?
getContent = content
getPaperId = uid

data GithubConfig = GC {
      username :: Text
    , oauth    :: Text
    } deriving (Show, Eq, Ord)

githubSpec :: ValueSpec GithubConfig
githubSpec = sectionsSpec "github" $
         do username <- reqSection "username" "GitHub username"
            oauth <- reqSection "oauth" "OAuth Token for GitHub"
            pure GC{..}

-- html page stuff

pageTemplate :: Monad m => Text -> HtmlT m a -> HtmlT m a
pageTemplate title content = do
  doctype_
  html_ $ do
    head_ $
      title_ $ toHtml title
    body_ content

papersadd :: Monad m => Day -> HtmlT m ()
papersadd nowTime = do
  form_ [action_ "/paper", method_ "post", enctype_ "multipart/form-data"] $ do
              label_ "DOI"
              input_ [type_ "text", name_ "doi"]
              label_ "Title"
              input_ [type_ "text", name_ "title"]
              label_ "Authors"
              input_ [type_ "text", name_ "author"]
              label_ "Publication Date"
              input_ [type_ "text", name_ "pubdate", value_ (pack . show $ nowTime)]
              label_ "PDF of file"
              input_ [type_ "file", name_ "uploadedfile"]
              input_ [type_ "submit"]

paperstable :: Monad m => [Paper] -> HtmlT m ()
paperstable rows =
  table_ $ do
    tr_ $
      th_ "Rows"
    sequence_ $ onepaper <$> rows

onepaper :: Monad m => Paper -> HtmlT m ()
onepaper r = tr_ $
  do td_ $ do
       a_ [href_ ("/index.html" <> "?pagenum=1" <> "&uid=" <> uid r)] (toHtml $ title r)
     tdit (T.pack . show . published :: Paper -> Text)
     tdit uid
     tdit author
          where tdit f = td_ . toHtml $ f r
                ruid = uid r

-- ?doi=10.25&title=this+is+a+title&author=Shae+Erisson&pubdate=2019-01-01
mbP :: [Param] -> Maybe Paper
mbP d = let upl = flip lookup d in
        do d <- upl "doi"
           t <- upl "title"
           a <- upl "author"
           pd <- upl "pubdate"
           mpd <- readMaybe $ TL.unpack pd -- there's got to be a better way
           return $ Paper (TL.toStrict d) (TL.toStrict a) mpd (TL.toStrict t) []

-- dunno if this is any better
mbP' :: [Param] -> Maybe Paper
mbP' ps = Paper
          <$> (supl "doi")
          <*> (supl "author")
          <*> (join $ readMaybe <$> (TL.unpack <$> upl "pubdate")) -- SO MUCH CHEESE, lifting everything to Maybe then joining?!
          <*> (supl "title")
          <*> Just []
    where upl = flip lookup ps
          supl a = TL.toStrict <$> upl a

-- find file in subdirs
findPaper :: FilePath -> FilePath -> IO [FilePath]
findPaper top match = find always (fileName ~~? match) top

-- random useful thing
third (a,b,c) = c

-- convert a file into static page images
renderPageImages :: FilePath -> IO (ExitCode, Text)
renderPageImages fp = do
  (Nothing, Nothing, Just errh, pid) <- createProcess (proc "pdftocairo" ["-png", "paper.pdf", "page"]) { cwd = Just fp, std_in = NoStream, std_out = NoStream, std_err = CreatePipe, close_fds = True}
  exitCode <- waitForProcess pid
  result <- decodeUtf8 <$> BS.hGetContents errh
  renameZ fp
  return (exitCode, result)

-- f <- find always (fileName ~~? "page-*.png") "/home/shae/.fermatslastmargin/pageimages/10.4204/EPTCS.275.6"
-- splitFileName $ head f
-- ("/home/shae/.fermatslastmargin/pageimages/10.4204/EPTCS.275.6/","page-01.png")
renameZ :: FilePath -> IO ()
renameZ fp = do
  names <- find always (fileName ~~? "page-*.png") fp
  mapM_ (renameWith changeWholePath) names

-- | should convert like this: foo/bar/page-0001.png -> foo/bar/page-1.png
changeWholePath fp =  uncurry combine . fixName $ splitFileName fp
    where fixName = \(x,y)-> (x,fixZ y)

-- ugly, but works, kinda?
fixZ n@('p':'a':'g':'e':'-':xs) = "page-" <> killZeroes xs
fixZ n                          = n

killZeroes ('0':xs) = killZeroes xs
killZeroes x        = x
