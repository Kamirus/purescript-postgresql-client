module Test.Main
  ( main
  ) where

import Prelude

import Control.Monad.Error.Class (catchError, throwError, try)
import Control.Monad.Free (Free)
import Data.Array (zip)
import Data.Date (Date, canonicalDate)
import Data.DateTime.Instant (Instant, unInstant)
import Data.Decimal as D
import Data.Enum (toEnum)
import Data.Foldable (all, length)
import Data.JSDate (toInstant)
import Data.JSDate as JSDate
import Data.Maybe (Maybe(..), fromJust)
import Data.Newtype (unwrap)
import Data.Tuple (Tuple(..))
import Database.PostgreSQL (Connection, PoolConfiguration, Query(Query), Row0(Row0), Row1(Row1), Row2(Row2), Row3(Row3), Row9(Row9), execute, newPool, query, scalar, withConnection, withTransaction)
import Effect (Effect)
import Effect.Aff (Aff, error, launchAff)
import Effect.Class (liftEffect)
import Math ((%))
import Partial.Unsafe (unsafePartial)
import Test.Assert (assert)
import Test.Unit (TestF, suite)
import Test.Unit as Test.Unit
import Test.Unit.Assert (equal)
import Test.Unit.Main (runTest)

withRollback
  ∷ ∀ a
  . Connection 
  → Aff a
  → Aff Unit
withRollback conn action = do
  execute conn (Query "BEGIN TRANSACTION") Row0
  catchError (action >>= const rollback) (\e -> rollback >>= const (throwError e))
  where
  rollback = execute conn (Query "ROLLBACK") Row0

test
  ∷ ∀ a
   . Connection
  → String
  → Aff a
  → Free TestF Unit
test conn t a = Test.Unit.test t (withRollback conn a)

now ∷ Effect Instant
now = unsafePartial $ (fromJust <<< toInstant) <$> JSDate.now

main ∷ Effect Unit
main = void $ launchAff do
  pool <- newPool config
  withConnection pool \conn -> do
    execute conn (Query """
      CREATE TEMPORARY TABLE foods (
        name text NOT NULL,
        delicious boolean NOT NULL,
        price NUMERIC(4,2) NOT NULL,
        added TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (name)
      );
      CREATE TEMPORARY TABLE dates (
        date date NOT NULL
      );
    """) Row0

    liftEffect $ runTest $ do
      suite "Postgresql client" $ do
        let
          testCount n = do
            count <- scalar conn (Query """
              SELECT count(*) = $1
              FROM foods
            """) (Row1 n)
            liftEffect <<< assert $ count == Just true

        Test.Unit.test "transaction commit" $ do
          withTransaction conn do
            execute conn (Query """
              INSERT INTO foods (name, delicious, price)
              VALUES ($1, $2, $3)
            """) (Row3 "pork" true (D.fromString "8.30"))
            testCount 1
          testCount 1
          execute conn (Query """
            DELETE FROM foods
          """) Row0

        Test.Unit.test "transaction rollback" $ do
          _ <- try $ withTransaction conn do
            execute conn (Query """
              INSERT INTO foods (name, delicious, price)
              VALUES ($1, $2, $3)
            """) (Row3 "pork" true (D.fromString "8.30"))
            testCount 1
            throwError $ error "fail"
          testCount 0

        let
          insertFood =
            execute conn (Query """
              INSERT INTO foods (name, delicious, price)
              VALUES ($1, $2, $3), ($4, $5, $6), ($7, $8, $9)
            """) (Row9
                "pork" true (D.fromString "8.30")
                "sauerkraut" false (D.fromString "3.30")
                "rookworst" true (D.fromString "5.60"))
        test conn "select column subset" $ do
          insertFood
          names <- query conn (Query """
            SELECT name, delicious
            FROM foods
            WHERE delicious
            ORDER BY name ASC
          """) Row0
          liftEffect <<< assert $ names == [Row2 "pork" true, Row2 "rookworst" true]

        test conn "handling instant value" $ do
          before <- liftEffect $ (unwrap <<< unInstant) <$> now
          insertFood
          added <- query conn (Query """
            SELECT added
            FROM foods
          """) Row0
          after <- liftEffect $ (unwrap <<< unInstant) <$> now
          -- | timestamps are fetched without milliseconds so we have to
          -- | round before value down
          liftEffect <<< assert $ all
            (\(Row1 t) ->
              ( unwrap $ unInstant t) >= (before - before % 1000.0)
                && after >= (unwrap $ unInstant t))
            added

        test conn "handling decimal value" $ do
          insertFood
          sauerkrautPrice <- query conn (Query """
            SELECT price
            FROM foods
            WHERE NOT delicious
          """) Row0
          liftEffect <<< assert $ sauerkrautPrice == [Row1 (D.fromString "3.30")]

        test conn "handling date value" $ do
          let
            date y m d =
              canonicalDate <$> toEnum y <*>  toEnum m <*> toEnum d
            d1 = unsafePartial $ fromJust $ date 2010 2 31
            d2 = unsafePartial $ fromJust $ date 2017 2 1
            d3 = unsafePartial $ fromJust $ date 2020 6 31

          execute conn (Query """
            INSERT INTO dates (date)
            VALUES ($1), ($2), ($3)
          """) (Row3 d1 d2 d3)

          (dates :: Array (Row1 Date)) <- query conn (Query """
            SELECT *
            FROM dates
            ORDER BY date ASC
          """) Row0
          equal 3 (length dates)
          liftEffect <<< assert $ all (\(Tuple (Row1 r) e) -> e == r) $ (zip dates [d1, d2, d3])


config :: PoolConfiguration
config =
  { user: "postgres"
  , password: "lol123"
  , host: "127.0.0.1"
  , port: 5432
  , database: "purspg"
  , max: 10
  , idleTimeoutMillis: 1000
  }
