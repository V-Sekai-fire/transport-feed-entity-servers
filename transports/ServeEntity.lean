import EntityServer.Tick
def main : IO UInt32 := do
  let env (k d : String) := do pure ((← IO.getEnv k).getD d)
  let host ← env "HOST" "127.0.0.1"
  let port := (← env "PORT" "3001").toNat!
  let ticks := (← env "TICKS" "320").toNat!
  IO.println (← EntityServer.run host port.toUInt32 ticks.toUInt32 0)
  pure 0
