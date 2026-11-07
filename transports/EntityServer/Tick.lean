namespace EntityServer
@[extern "lean_entity_run"] opaque run (host : @& String) (port ticks slowNs : UInt32) : IO String
end EntityServer
