# Windows `require` performance optimizations

A stack of 5 commits that speed up `require` on Windows, primarily for
native-extension-heavy gems (GUI bindings, ORMs, etc.) and stat-heavy pure-Ruby
load chains.

## Headline results

Measured on Windows 11 25H2, Ruby HEAD (4.1.0dev, `master a6e302509b` plus this
stack), MSYS2 ucrt64 toolchain. Each benchmark runs `ruby -e 'require "X"'` in
a fresh process 5 times; the figure below is the steady-state average of
runs 2-5 (after OS file cache warm-up).

| Library | Upstream Ruby 4.0.5 (DevKit, no patches) | HEAD + this stack | Speedup |
|--------------|---------:|---------:|--------:|
| `gtk3`             | 2434 ms | **1755 ms** | **1.39×** |
| `concurrent-ruby`  |  301 ms | **111 ms**  | **2.71×** |
| `tzinfo`           |  ~150 ms | ~145 ms     | ~1.03×  |
| `sqlite3`          |  ~45 ms | ~45 ms      | ~1.00×  |

`gtk3` saves ~679 ms (28%) end-to-end. `concurrent-ruby` saves ~190 ms (63%).
Pre-existing fast pure-Ruby and small-native cases (`tzinfo`, `sqlite3`) are
unchanged — they were never stat- or GC-bound.

## The 5 commits

In `git log --oneline` order (newest first; all on top of upstream `master`).

### 1. `eb0f7b0d32 win32: stat fast paths`

`win32/win32.c`'s `winnt_stat()` was doing `CreateFile` →
`GetFileInformationByHandle` → `GetFileType` → `get_handle_pathname` →
`CloseHandle` for every existing file. Five syscalls per stat call.

Replaced with two layered fast paths:

* **Win11 24H2+:** `GetFileInformationByName(FileStatByNameInfo, …)`. Single
  syscall returning `FILE_STAT_INFORMATION` — file ID, all four timestamps,
  sizes, attributes, reparse tag, link count, effective access. Lets us
  populate `st_ino` and `st_nlink` accurately (the previous slow path was the
  only one that did that; the existing `stat_by_find` fallback already used
  the `st_ino=0 / st_nlink=1` compromise we now also adopt for the
  GetFileAttributesExW fallback below). Dynamic-loaded via `GetProcAddress` so
  Windows 10 hosts fall through.
* **Win10+ fallback:** `GetFileAttributesExW(GetFileExInfoStandard, …)`.
  Single syscall returning attrs + 3 FILETIMEs + size. Same `st_ino=0 /
  st_nlink=1` compromise as `stat_by_find`.

Both fast paths handle `lstat==TRUE` on non-reparse-point files (the
link's attrs == the file's attrs in that case). Reparse points (symlinks,
AF_UNIX sockets) still fall through to the original handle-based logic
which inspects `IO_REPARSE_TAG_*`.

Instrumentation counters (atexit-printed via `atomic` `Interlocked*`) confirm
**0 slow-path stat calls** during `require "gtk3"` after this commit (down
from ~90% slow path before).

Per-call timings (microbench, 200,000 iterations):

| Operation | Before | After (GetFileAttributesEx path) | After (GetFileInformationByName path) |
|-----------|--------:|---------:|---------:|
| `File.exist?(existing)` | 114 µs | 21 µs | ~21 µs |
| `File.stat(existing)`   | 112 µs | 21 µs | ~21 µs |
| `File.exist?(missing)`  |  21 µs | 11 µs | ~11 µs |

5.4× per-call speedup for existing-file stat.

### 2. `ce8b62f4b5 file: GetFinalPathNameByHandleW fast path in rb_check_realpath_internal`

Ruby's portable `realpath_rec` walker stats every path component to follow
symlinks. On Windows that's ~14 stats per typical-depth path, repeated for
every entry added to `$LOADED_FEATURES`.

Added `rb_w32_realpath()` in `win32/win32.c`: `CreateFileW` →
`GetFinalPathNameByHandleW(FILE_NAME_NORMALIZED)` → `CloseHandle`. Three
syscalls regardless of path depth. Normalizes the result's backslashes to
forward slashes so `$LOADED_FEATURES` dedupes correctly (Ruby's canonical
form uses `/`).

The hook in `file.c`'s `rb_check_realpath_internal()` is gated `#ifdef _WIN32`
and only fires for non-`RB_REALPATH_DIR` mode. Relative paths, missing files,
and access errors all return `NULL` from the helper, falling through to the
existing `rb_check_realpath_emulate()` walker which handles those cases
correctly.

Stat-call count during `require "gtk3"`: **2495 → 413 (83% reduction)**.

### 3. `994cc82dc6 dln: LoadLibraryExW with LOAD_WITH_ALTERED_SEARCH_PATH`

Replaces the legacy `LoadLibraryW(winfile)` in `dln.c` (native extension
loader) with `LoadLibraryExW(winfile, NULL, LOAD_WITH_ALTERED_SEARCH_PATH)`.
The flag tells the Windows loader to search the `.so`'s own directory first
when resolving transitive imports (so gems that bundle their DLLs alongside
the `.so` get picked up without walking PATH).

Wall-clock impact on this VM is noise (gtk3's transitive deps live in
`ucrt64/bin` via PATH, not next to the `.so` — so the altered search doesn't
find anything new). Kept anyway because:

1. It's the recommended modern form on Win10+ (legacy `LoadLibraryW`
   includes current directory in its search, which is a security risk).
2. It composes correctly with the opt-in user-dirs mode (next commit).
3. It costs nothing.

### 4. `a585e12664 win32+dln: opt-in AddDllDirectory / User-Dirs LoadLibrary search`

Adds a `RUBY_DLL_PATH` environment variable. When set, `rb_w32_sysinit()`:

1. Calls `AddDllDirectory()` for both ruby.exe's own directory and the value
   of `RUBY_DLL_PATH` (typically a `ucrt64/bin`-style deps directory).
2. Calls `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)`. This
   switches the process from legacy PATH-walking DLL search to a strict
   "only registered user dirs + System32 + app dir" mode.
3. Sets a global `g_w32_use_user_dll_dirs = 1`.

`dln.c` reads that global. In opt-in mode it uses `LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
| LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR`. Otherwise it stays on
`LOAD_WITH_ALTERED_SEARCH_PATH` (commit 3 above).

Wall-clock impact: also noise (~0 ms). The cost in modern Windows
`LoadLibrary` is not in path resolution — it's in PE relocation and DllMain
execution. Kept anyway because it's the right primitive to enable when
shipping a self-contained Ruby distribution (avoids accidentally picking up
random DLLs on PATH).

Note: must NOT enable unconditionally. Calling
`SetDefaultDllDirectories()` disables PATH walking process-wide — without
the named deps directory registered, gems that depend on DLLs in PATH break
with "the parameter is incorrect" (we hit this; that's why this is opt-in).

### 5. `d7b73553da load: disable GC during the require chain (rb_ensure-safe)`

Discovery: `require "gtk3"` triggers **~64 GC runs** during load due to high
allocation rates in initialization code (parsing, hash/string churn, GObject
wrappers). Profile: ~17% of wall-clock was GC.

Wrapped `require_internal()` with a thin dispatcher (renamed the original to
`require_internal_unguarded`) that:

1. Calls `rb_gc_disable()` and records the prior state (`Qtrue` if GC was
   already disabled by user code or an outer require).
2. Calls the unguarded require via `rb_ensure()`.
3. The ensure handler re-enables GC only if it was enabled at entry.

Nesting / exception handling is correct because `rb_ensure` guarantees the
ensure handler runs even on exception unwind, and the "already disabled"
short-circuit means nested requires don't toggle GC.

Result: `require "gtk3"` 2074 → 1755 ms (-15.4%). `concurrent-ruby` /
`tzinfo` / `sqlite3` unchanged because they don't allocate enough during
require to trigger meaningful GC (1 GC each).

Side effect: peak memory during `require "gtk3"` is briefly higher (all the
load-time churn isn't reclaimed until after the require returns). For
long-running applications this is a no-op because the post-init GC catches
up immediately. For one-shot scripts that `require "gtk3"` and exit, peak
memory is observable but inconsequential.

## What was tried and didn't help

* `LoadLibraryExW` with `LOAD_LIBRARY_SEARCH_USER_DIRS` instead of
  `LOAD_WITH_ALTERED_SEARCH_PATH` (commit 4 above). On modern Windows, PATH
  walking isn't the LoadLibrary bottleneck. The cost is in PE relocation
  and DllMain — kernel work not addressable from Ruby.
* Naive realpath fast path **without** normalizing `\` to `/`. Caused
  `$LOADED_FEATURES` to see the same file under two spellings, leading to
  double-loads ("already initialized constant Prism::BACKEND" warnings,
  cascading NameErrors in `concurrent-ruby`). Fixed by the slash
  normalization in commit 2.
* Combining `LOAD_WITH_ALTERED_SEARCH_PATH` with `LOAD_LIBRARY_SEARCH_*`
  flags — those are mutually exclusive per MSDN; combining produces
  `ERROR_INVALID_PARAMETER`.

## Benchmark methodology

The benchmarks measure cold-process `require` time — every iteration is a
fresh `ruby -e '...'` subprocess so there's no in-process warm-up. The OS
file cache is warm by the second iteration; we report the steady-state
average of iterations 2-5 (iteration 1 is reported separately for
informational purposes).

Allocation counter `GC.count` is captured at end-of-require to confirm how
many GCs ran (used to motivate commit 5).

Stat-call counters in commit 1 are exposed via a small `atexit` printer on
stderr — easy to disable by removing the `atexit(winnt_stat_print_stats)`
call and the `InterlockedIncrement` calls in `winnt_stat()`. Kept enabled
in this branch for ongoing profiling.

## Caveats

* `rb_w32_realpath` populates `st_ino = 0` and `st_nlink = 1`
  (matching the existing `stat_by_find` fallback's semantic compromise) when
  the `GetFileAttributesExW` path is taken. `File.identical?` between hard
  links may give wrong answers in that path. The `GetFileInformationByName`
  path (Win11 24H2+) populates real values.
* The GC-disable wrapper in commit 5 increases peak memory during heavy
  requires. For typical apps this is invisible; for memory-constrained
  embedded use cases it could matter.
* The `RUBY_DLL_PATH` mechanism (commit 4) is opt-in and requires careful
  configuration — switching to user-dirs mode without registering the deps
  directory breaks every native-extension load. Don't set it unless you
  know your deps location.

## How to test

```sh
cd /c/work/ruby
git log --oneline -7      # see this stack on top of upstream HEAD
make -j$(nproc)
make install              # installs to whatever you configured --prefix with

# Smoke
/c/ruby-head/bin/ruby --version
/c/ruby-head/bin/ruby -e 'require "gtk3"; puts "loaded"'

# Microbench (after installing gtk3, concurrent-ruby, tzinfo, sqlite3 gems)
/c/ruby-head/bin/ruby -e '
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  require "gtk3"
  printf "%.3f ms (%d features, %d GCs)\n",
    (Process.clock_gettime(Process::CLOCK_MONOTONIC)-t0)*1000,
    $LOADED_FEATURES.length, GC.count
'
```

## Open follow-ups

* Remove the `atexit`-printed stat counters before upstreaming. They were
  added for profiling and aren't useful in production builds.
* Consider hoisting the `st_ino=0 / st_nlink=1` compromise into a feature
  query — extensions that genuinely need accurate inode info on the fast
  path could request the slow path.
* The opt-in `RUBY_DLL_PATH` mechanism could be wired to derive its value
  from `RbConfig::CONFIG[:bindir]` automatically, eliminating the env-var
  configuration step for self-contained installations.
* Investigate further LoadLibrary speedups (binding imports at build time,
  preloading common deps eagerly). Out of scope for this stack — those
  changes need to happen at the gem-build or Ruby-distribution level, not
  here.
