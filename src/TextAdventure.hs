module TextAdventure
    -- | Data types.
    ( GameAction
    , Options(..)
    , GameState
    , Adventure(..)
    , Nexus(..)
    , Output(..)
    -- | Type constructors.
    , dispatcher
    , defaultOptions
    , defaultGameState
    -- | Execution.
    , run
    , play
    -- | Control flow.
    , dispatch
    , toAction
    , runPrompt
    , cmdPrompt, cmdPrompt_
    , prompt, prompt_
    , pause, pause_
    , retry
    -- | Output.
    , printLines, printLines_
    , printWrap, printWrap_
    , hr, hr_, blankLine
    ) where

import           Control.Monad        (void)
import           Control.Monad.Reader (ReaderT, asks, runReaderT)
import           Control.Monad.State  (StateT, get, liftIO, put, runStateT)
import           Data.List            (intercalate)
import qualified Data.Map             as Map

import           TextAdventure.Internal.StringUtils          (normalize, strip, wordWrap)
import           TextAdventure.Internal.TemplateString       (format)


--------------------------------------------------------------------------------
--  Game data.


-- | A GameAction performs IO with some associated @GameState@ and @Options@.
type GameAction a =
    ReaderT Options (StateT GameState IO) a


-- | A mapping of the current game state.
type GameState =
    Map.Map String String


-- | A record of fixed display options.
data Options = Options
    -- | The current prompt characters, such as ">> ".
    { getPromptChars :: String
    -- | The current text width to wrap to. This is unlikely to change.
    , getTextWidth   :: Int
    -- | The current line character. Used for drawing a horizontal rule with @HR@.
    , getLineChar    :: Char

    } deriving (Show, Eq)


-- | An adventure game.
-- This is a recursive tree structure where each Node has an arbitrary amount
-- of branches corresponding with each path the game can take at that point
-- (@Nexus@). The Node itself represents a series of @Output@s as a list.
data Adventure =
    Node [Output] Nexus
    deriving (Show, Read, Eq)


-- | A Map of choices to @Adventure@s with a corresponding prompt message,
-- or a game over with a game over message. See @Adventure@.
data Nexus
    = Dispatch String (Map.Map String Adventure)
    | EndGame String
    deriving (Show, Read, Eq)


-- | Represents game output, such as printing a string, prompting for an answer,
-- or pausing the game.
data Output
    = Print String
    | PrintLines [String]
    | Prompt String [String] String
    | HR
    | BlankLine
    | Pause
    deriving (Show, Read, Eq)


-- | Smart constructor for a Dispatch Nexus.
dispatcher :: String -> [(String, Adventure)] -> Nexus
dispatcher msg assoc =
    Dispatch msg (Map.fromList assoc)


-- | Default options.
defaultOptions :: Options
defaultOptions = Options
    { getPromptChars = ">> "
    , getTextWidth = 78
    , getLineChar = '-'
    }


-- | Default game state.
defaultGameState :: GameState
defaultGameState =
    Map.empty


--------------------------------------------------------------------------------
--  Control flow.


-- | Run a game, given an @Adventure@ and a @GameState@.
run :: Adventure -> Options -> GameState -> IO ()
run adventure opts gameState =
    void $ runStateT (runReaderT (play adventure) opts) gameState


-- | Convert an @Adventure@ to a @GameAction@.
play :: Adventure -> GameAction ()
play (Node outputs disp) =
    mapM_ toAction outputs >> dispatch disp


-- | Given a @Dispatch@ @Nexus@, prompt for an answer and then @play@ the
-- corresponding @Adventure@, retrying on invalid input. End the game
-- with a message given an @EndGame@ @Nexus@.
dispatch :: Nexus -> GameAction ()

dispatch (EndGame msg) =
    printWrap_ msg

dispatch this@(Dispatch msg paths) = do
    let paths' = Map.mapKeys normalize paths

    printWrap msg
    choice <- cmdPrompt_ (Map.keys paths')

    case Map.lookup choice paths' of
        Nothing        ->
            retry (dispatch this)

        Just adventure ->
            play adventure


-- | Convert an @Output@ to a @GameAction@.
toAction :: Output -> GameAction ()
toAction output =
    case output of
        Print str ->
            printWrap_ str

        PrintLines strs ->
            printLines_ strs

        Prompt var choices str ->
            runPrompt var choices str

        HR ->
            hr_

        BlankLine ->
            blankLine

        Pause ->
            pause


-- | Given a variable name, a list of choices, and a message, print the message
-- and then prompt for an answer updating the @getVars@ attribute of the
-- current @GameState@ with the result. If choices is an empty list,
-- use @prompt_@ and retry on no input. If some choices are given, use
-- @cmdPrompt_@ and retry on invalid input.
runPrompt :: String -> [String] -> String -> GameAction ()
runPrompt var choices str = do
    answer <-
        if null choices
            then prompt_ str
            else printWrap str >> cmdPrompt_ choices

    if null answer || (not (null choices) && (answer `notElem` choices))
        then retry $ runPrompt var choices str
        else do
            vars <- get
            let newVars = Map.insert var answer vars
            put newVars


-- | Like @prompt@, but prints a given list of possible choices and prints
-- them, then prompts for a result, normalizing the input with @normalize@.
cmdPrompt :: [String] -> GameAction String
cmdPrompt choices = do
    promptChars <-
        asks getPromptChars

    liftIO $ do
        let choicesStr = "(" ++ intercalate ", " choices ++ ")"
        putStr $ choicesStr ++ (' ' : promptChars)

        choice <- getLine
        return $ normalize choice


-- | @cmdPrompt@ with a blank line added to the end.
cmdPrompt_ :: [String] -> GameAction String
cmdPrompt_ cs =
    cmdPrompt cs >>= \x -> blankLine >> return x


-- | Print something then prompt for input.
prompt :: String -> GameAction String
prompt message = do
    vars <- get
    promptChars <- asks getPromptChars

    printWrap message

    liftIO $ do
        putStr promptChars
        fmap strip getLine


-- | @prompt@ with a blank line added to the end.
prompt_ :: String -> GameAction String
prompt_ msg =
    prompt msg >>= \x -> blankLine >> return x


-- | Print a "try again" message and re-execute the given @GameAction@.
retry :: GameAction () -> GameAction ()
retry action = do
    liftIO $ putStrLn "Invalid input. Please try again."
    blankLine >> action


-- | Pause execution and wait for a keypress to continue.
pause :: GameAction ()
pause =
    liftIO $ putStr "(Press <Enter> to continue...)" >> void getLine


-- | @pause@ with a blank line added to the end.
pause_ :: GameAction ()
pause_ =
    pause >> blankLine


--------------------------------------------------------------------------------
--  Output.


-- | Print a list of Strings line by line, wrapping each line to the given width.
printLines :: [String] -> GameAction ()
printLines =
    mapM_ printWrap


-- @printLines@ with a blank line added to the end.
printLines_ :: [String] -> GameAction ()
printLines_ xs =
    printLines xs >> blankLine


-- | Print a String, wrapping its text to the given width.
printWrap :: String -> GameAction ()
printWrap str = do
    textWidth <- asks getTextWidth
    vars <- get

    let eitherStr = format str vars
        errorFunc e = error $ "Error: " ++ e
        newStr = either errorFunc id eitherStr

    liftIO . putStrLn . wordWrap textWidth $ newStr


-- | @printWrap@ with a blank line added to the end.
printWrap_ :: String -> GameAction ()
printWrap_ str =
    printWrap str >> blankLine


-- | Print a horizontal rule.
hr :: GameAction ()
hr = do
    width <- asks getTextWidth
    char <- asks getLineChar
    liftIO $ putStrLn (replicate width char)


-- | @hr@ with a blank line added to the end.
hr_ :: GameAction ()
hr_ =
    hr >> blankLine


-- | Print a blank line.
blankLine :: GameAction ()
blankLine =
    liftIO $ putChar '\n'
