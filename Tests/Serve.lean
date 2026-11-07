import FeedServer
open FeedServer

def main : IO UInt32 := do
  let env (k d : String) := do pure ((← IO.getEnv k).getD d)
  let path ← env "SQLITE_PATH" "feed.db"
  let secret ← env "JWT_SECRET" ""
  let host ← env "HOST" "127.0.0.1"
  let port := (← env "PORT" "3000").toNat!
  Server.run path secret host port.toUInt32
