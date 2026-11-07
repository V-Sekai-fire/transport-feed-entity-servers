import Lake
open Lake DSL System

package «iouring-feed-server-lean» where
  version := v!"0.1.0"

@[default_target]
lean_lib FeedServer

lean_lib TestSupport where
  srcDir := "Tests"
  roots := #[`Fake]

/-- SQLite options from reference/build.rs. -/
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
  let src ← inputTextFile (pkg.dir / "csrc" / "shim.c")
  buildO oFile src (#["-I", (pkg.dir / "reference" / "vendor").toString] ++ sqliteDefs)

target glue.o pkg : FilePath := do
  let oFile := pkg.buildDir / "csrc" / "lean_glue.o"
  let src ← inputTextFile (pkg.dir / "csrc" / "lean_glue.c")
  let inc ← getLeanIncludeDir
  buildO oFile src #["-I", inc.toString, "-O2", "-fPIC"]

extern_lib libtd pkg := do
  let shim ← shim.o.fetch
  let glue ← glue.o.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "td") #[shim, glue]

def linkLibs : Array String := if System.Platform.isOSX then #[] else #["-lpthread", "-lm"]

lean_exe «feed-tests» where
  root := `Tests.Main
  moreLinkArgs := linkLibs

lean_exe «sqlite-check» where
  root := `Tests.SqliteCheck
  moreLinkArgs := linkLibs
