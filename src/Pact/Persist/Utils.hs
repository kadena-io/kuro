module Pact.Persist.Utils
  ( throwDbError' ) where

import Control.Monad.Catch (MonadThrow)
import Data.Text.Prettyprint.Doc

import qualified Pact.Types.Runtime as P (throwDbError)


throwDbError' :: MonadThrow m => String -> m a
throwDbError' s = P.throwDbError $ pretty s
