import Lake
open Lake DSL System

package «transport-iouring-feed-server» where
  version := v!"0.1.0"

lean_lib Entities where
  srcDir := "entities"
  roots := #[`FeedServer.Http, `FeedServer.Json, `FeedServer.Sha256, `FeedServer.Jwt, `FeedServer.App, `FeedServer.Record]

lean_lib Repositories where
  srcDir := "repositories"
  roots := #[`FeedServer.Db]

lean_lib Datasources where
  srcDir := "datasources"
  roots := #[`FeedServer.Sqlite]

@[default_target]
lean_lib Transports where
  srcDir := "transports"
  roots := #[`FeedServer.All, `FeedServer.Conn, `FeedServer.Server, `EntityServer.Tick]

lean_lib TestSupport where
  srcDir := "entities/spec"
  roots := #[`Fake]

/-- SQLite options from datasources/reference/build.rs. -/
def sqliteDefs : Array String := #[
  "-DSQLITE_THREADSAFE=2", "-DSQLITE_DEFAULT_MEMSTATUS=0", "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
  "-DSQLITE_DQS=0", "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS", "-DSQLITE_MAX_EXPR_DEPTH=0",
  "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_OMIT_PROGRESS_CALLBACK", "-DSQLITE_OMIT_SHARED_CACHE",
  "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_AUTOINIT", "-DSQLITE_OMIT_UTF16",
  "-DSQLITE_OMIT_TRACE", "-DSQLITE_OMIT_COMPLETE", "-DSQLITE_OMIT_GET_TABLE",
  "-DSQLITE_OMIT_TCL_VARIABLE", "-DSQLITE_USE_ALLOCA", "-DHAVE_FDATASYNC=1", "-DHAVE_USLEEP=1",
  "-O2", "-w"]

target shim.o pkg : FilePath := do
  let oFile := pkg.buildDir / "csrc" / "shim.o"
  let src ← inputTextFile (pkg.dir / "datasources" / "csrc" / "shim.c")
  let lean ← getLeanInstall
  let cc : FilePath := "cc"
  let fl : Array String := #["-fPIC"]
  buildO oFile src (fl ++ #["-I", (pkg.dir / "datasources" / "reference" / "vendor").toString, "-I", (pkg.dir / "datasources" / "store").toString] ++ sqliteDefs) #[] cc

target glue.o pkg : FilePath := do
  let oFile := pkg.buildDir / "csrc" / "lean_glue.o"
  let src ← inputTextFile (pkg.dir / "datasources" / "csrc" / "lean_glue.c")
  let inc ← getLeanIncludeDir
  let lean ← getLeanInstall
  let cc : FilePath := "cc"
  let fl : Array String := #["-fPIC"]
  buildO oFile src (fl ++ #["-I", inc.toString, "-O2", "-fPIC"]) #[] cc

target entity.o pkg : FilePath := do
  let oFile := pkg.buildDir / "csrc" / "entity_tick.o"
  let src ← inputTextFile (pkg.dir / "transports" / "csrc" / "entity_tick.c")
  buildO oFile src #["-O2", "-fPIC"] #[] "cc"
target entityglue.o pkg : FilePath := do
  let oFile := pkg.buildDir / "csrc" / "entity_glue.o"
  let src ← inputTextFile (pkg.dir / "transports" / "csrc" / "entity_glue.c")
  let inc ← getLeanIncludeDir
  buildO oFile src #["-I", inc.toString, "-O2", "-fPIC"] #[] "cc"
target ring.o pkg : FilePath := do
  let oFile := pkg.buildDir / "csrc" / "ring_glue.o"
  let src ← inputTextFile (pkg.dir / "transports" / "csrc" / "ring_glue.c")
  let inc ← getLeanIncludeDir
  buildO oFile src #["-I", inc.toString, "-O2", "-fPIC"] #[] "cc"

extern_lib libtd pkg := do
  let shim ← shim.o.fetch
  let glue ← glue.o.fetch
  let ring ← ring.o.fetch
  let ent ← entity.o.fetch
  let eg ← entityglue.o.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "td") #[shim, glue, ring, ent, eg]

/-- The store's FoundationDB VFS (subtree at datasources/store/), built against this repo's vendored sqlite3.h. -/
target fdbvfs.o pkg : FilePath := do
  let oFile := pkg.buildDir / "csrc" / "fdb_vfs.o"
  let hdr : FilePath := "/usr/include/foundationdb/fdb_c.h"
  if (← hdr.pathExists) then
    let src ← inputTextFile (pkg.dir / "datasources" / "store" / "fdb_vfs.c")
    buildO oFile src #["-fPIC", "-O2", "-DFDB_API_VERSION=730", "-I", (pkg.dir / "datasources" / "store").toString, "-I", (pkg.dir / "datasources" / "reference" / "vendor").toString, "-I", "/usr/include/foundationdb"] #[] "cc"
  else
    let src ← inputTextFile (pkg.dir / "datasources" / "csrc" / "fdb_stub.c")
    buildO oFile src #["-fPIC", "-I", (pkg.dir / "datasources" / "store").toString] #[] "cc"

extern_lib libweftfdb pkg := do
  let o ← fdbvfs.o.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "weftfdb") #[o]
/-- The FoundationDB client that libweftfdb (the store VFS) calls. -/
def fdbLibs : Array String :=
  if System.Platform.isOSX then #["-L/usr/local/lib", "-Wl,-rpath,/usr/local/lib", "-lfdb_c"] else #["-L/usr/lib", "-lfdb_c"]
def linkLibs : Array String := fdbLibs ++ if System.Platform.isOSX then #[] else #["-lpthread", "-lm"]

lean_exe «feed-tests» where
  srcDir := "entities/spec"
  root := `Main
  moreLinkArgs := linkLibs

lean_exe «sqlite-check» where
  srcDir := "datasources/spec"
  root := `SqliteCheck
  moreLinkArgs := linkLibs
  moreLinkArgs := linkLibs


def uringA : String :=
  if System.Platform.target.startsWith "aarch64" then "/usr/lib/aarch64-linux-gnu/liburing.a"
  else "/usr/lib/x86_64-linux-gnu/liburing.a"

def serveLibs : Array String := fdbLibs ++ if System.Platform.isOSX then #[] else #[uringA, "-lpthread", "-lm"]

lean_exe «feed-server» where
  srcDir := "transports"
  root := `Serve
  moreLinkArgs := serveLibs
lean_exe «entity-server» where
  srcDir := "transports"
  root := `ServeEntity
  moreLinkArgs := serveLibs
