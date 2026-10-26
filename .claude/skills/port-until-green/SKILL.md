---
name: port-until-green
description: Drive a yacp-dev/ports package update to a passing PR. Dispatches yacp-dev/dist's build-package workflow for the named package (creating the dorgann/<pkg>-<ver> branch, or rebuilding the one already there), and when the Windows/Cygwin build fails, investigates the log, fixes the recipe on that branch, commits, pushes and re-runs until it passes. Takes one argument: <pkg> (update to Repology's newest), <pkg>-<ver> (update to that version, or bump the release if it's the current one), or <pkg>-<ver>-<rel> (current release: build and deploy to dist; next release: gcc rebuild). Use this whenever the user names a ports/yacp package and wants it bumped, built, its PR made green, or its draft dorgann PR fixed — e.g. "/port-until-green knot", "ngtcp2 の PR 作って", "Catch2 のビルド直して" — even if they don't say "skill" or "workflow".
argument-hint: <pkg> | <pkg>-<ver> | <pkg>-<ver>-<rel>
---

# port-until-green

Get one package in [yacp-dev/ports](https://github.com/yacp-dev/ports) to a
ready (non-draft) PR, by looping: build on dorgann's CI → read the failure →
fix the recipe on the branch → build again.

One argument, whose shape decides what to do (Step 1 resolves it):

| Argument | Meaning |
|---|---|
| `<pkg>` | Update to the newest upstream version, found via Repology. Already current → say so and stop. |
| `<pkg>-<ver>` | Update to `<ver>`. Equal to the version in ports → bump only the release (`1bl1` → `1bl2`). |
| `<pkg>-<ver>-<rel>` | Equal to ports' version and release → build it as is and deploy it to dist (no PR). Same version, release one higher → gcc rebuild (`Rebuild with gcc-x.y.z`). Anything else → tell the user to give `<pkg>` or `<pkg>-<ver>` instead, and stop. |

`<pkg>` is the package's directory name in ports (`Catch2`; the resolver
also accepts `catch2`). A package not in ports yet takes `<pkg>-<ver>`
too: see "New packages" below.

## How the pieces fit (read once)

The build only runs on dorgann's `windows-latest` CI (`.github/workflows/build-package.yml`
in this repo, yacp-dev/dist). There's no local Cygwin, so every build
attempt is a workflow run, ~5–30 min each. Key behaviors:

- The workflow takes one `target` input, in the same three shapes as this
  skill's argument, and resolves it with the same
  `scripts/resolve_target.sh` (doc/spec.md 4.3) — except a bare `<pkg>`,
  which it refuses: Repology is looked up here, in Step 1.
- A `<pkg>-<ver>` dispatch bumps the recipe (or only its release). On
  success the workflow opens the PR on `dorgann/<pkg>-<ver>`; on failure
  it pushes the same branch as a **draft** PR — as long as the bump
  itself succeeded — and puts undefined-macro diagnostics in the run summary.
  No Issue is filed: the branch and draft PR are the record of a failed
  version.
- If `dorgann/<pkg>-<ver>` already exists, the dispatch automatically
  switches to branch-rebuild mode: it overlays the branch's changes onto
  master and rebuilds. So after pushing a fix, just dispatch the same
  target again. A version update or rebuild uses this from the start:
  the preflight (Step 1b) bumps the recipe here, fixes what it can tell
  will fail, and pushes the branch before the first dispatch, so the
  workflow's own `Bump version`/`Bump release` only runs when there's
  no branch yet.
- **The bot rewrites the branch on every run** (peter-evans/create-pull-request
  squashes everything into one `<pkg>-<ver>` commit and force-pushes). Your
  local branch is therefore stale after each run — always
  `git fetch && git reset --hard origin/<branch>` before editing, or your
  push will be rejected or will clobber the bot's commit.
- See `doc/spec.md` 4.5–4.6 for the full design if something here surprises you.

Helpers bundled with this skill (paths relative to this SKILL.md):

- `scripts/dispatch_build.sh --target T [-f key=val ...]` — dispatches and
  prints `<run id> <run url>`.
- `scripts/wait_run.sh --run ID [--interval SECS]` — waits for a run of
  either workflow
  (one API call every 90 s by default), prints `<conclusion> <run url>`,
  and exits 0 only on success.
- `scripts/failure_summary.sh --run ID --out DIR` — failed step names,
  the undefined-macro diagnostic (when that diagnose step ran), and the
  full failed log saved to `DIR` for grepping.
- `scripts/check_summary.sh --run ID` — whether `cygport check` passed,
  ran no tests (`check: empty`), or failed, with its diagnostic (Step 2).
- `scripts/preflight_bump.sh --package P --version V --work DIR [--source URL]` —
  bumps the recipe to `V` (only its release, when `V` is the current
  version) on a local `dorgann/P-V` branch in its own
  worktree (committed, not pushed), and reports what would fail: patches
  that don't apply to the new source, the SOVERSION, LICENSE, a
  superseded Python, unused CMake `-D` variables (Step 1b).
- `scripts/unused_cmake_args.sh --recipe F --source DIR [--old-source DIR]` —
  the `-D` variables a cmake recipe passes that no build file in `DIR`
  reads (preflight runs it; also usable on its own).
- `scripts/git_snapshot_bump.sh --package P [--version V] [--dry-run]` —
  bumps a git-snapshot package to upstream HEAD on its own branch, in
  its own worktree (see Step 1).
- `scripts/distro_patches.sh --project NAME --version V --out DIR` —
  downloads the patches Debian, Fedora and Gentoo carry for version `V`
  (Debian unstable, Fedora rawhide and the Gentoo tree, looked up
  directly; Repology only names the source packages), each with a
  revision-pinned URL for `PATCH_URI` (see
  "Distro patches" under Step 2).
- `scripts/cmux_status.sh "<text>"` / `--clear` — shows the package and
  phase as a status pill on this session's cmux workspace (a no-op
  outside cmux). See "Status pill" below.

### Status pill

Keep the user able to tell at a glance which package this session is on.
Set the pill once Step 1 has settled the target, and update it at each
phase change, as `<pkg>-<ver> · <phase>`:

| When | Phase text |
|---|---|
| Step 1b | `preflight` |
| Each dispatch (Step 2) | `build #N running` (N = attempt, transient re-runs included) |
| Step 3/4 | `fixing build #N` |
| Deploy publish | `publishing` |

Run it alongside the step's own command, not as an extra turn. When
the loop ends — success, stopping, or Step 1 stopping early (already up
to date, blocked, invalid) — clear it with `scripts/cmux_status.sh --clear`
as the last action before reporting.

## Step 1: Resolve the argument

```bash
bash scripts/resolve_target.sh --repo yacp-dev/ports --target <arg>
```

(dorgann's own `scripts/`, run from the repo root — the workflow's gate
job runs the same script.) It finds the package as the longest ports directory name the argument
starts with (package names can contain dashes), then splits the rest into
`<ver>[-<rel>]`. Act on its `mode=`:

- **`latest`** (`<pkg>`) → find the newest upstream version on Repology:
  `curl -s -A 'dorgann port-until-green' https://repology.org/api/v1/project/<name>`
  (without a User-Agent, Repology answers 200 with an empty body) and
  take a `"status": "newest"` entry's version (the project name may need
  lowercasing or a prefix like `python:`; normalize the spelling to the
  cygport's, e.g. `1_2_3` → `1.2.3`). Equal to `current_version` → tell
  the user it's already up to date and stop. Otherwise carry on as
  `bump` with that version. If Repology has no entry, or the "newest"
  looks like a distro fork/prerelease, ask the user instead of guessing
  — a wrong version means a wrong PR. (Git snapshots: see below.)
- **`bump`** (`<pkg>-<ver>`, `<ver>` differs from ports) → a version
  update to `<ver>`.
- **`rebuild`** (`<pkg>-<ver>`, `<ver>` equals ports) → bump only the
  release, e.g. `1bl1` → `1bl2`. `xezat bump` writes `Rebuild with
  gcc-<ver>` if the gcc differs from the one in the README's build
  requirements, else `Rebuild`. A rebuild for a fix the packages
  ship (a `.pc`, `REQUIRES`, a missing file) says what it fixes
  instead: see `changelog_message` in Step 2.
- **`gcc-rebuild`** (`<pkg>-<ver>-<rel>`, same version, `<rel>` is ports'
  release + 1) → the same release bump, taken as a rebuild for a newer
  gcc. The changelog message comes from `scripts/changelog_message.sh`,
  which writes `Rebuild with gcc-<ver>` only when gcc actually changed, so
  check that first: the README's gcc
  (`gh api repos/yacp-dev/ports/contents/<pkg>/README -H 'Accept: application/vnd.github.raw' | sed -n 's/^[[:space:]]*gcc-core-\(.*\)-[^-]*$/\1/p' | head -n 1`)
  against Cygwin curr's
  (`curl -s https://mirrors.kernel.org/sourceware/cygwin/x86_64/setup.xz | xz -d | awk '/^@ gcc-core$/{f=1;next} f&&/^version:/{print $2; exit}'`,
  minus its `-<release>`). Same → it would only say `Rebuild`; tell the
  user gcc hasn't changed and ask whether to go ahead.
- **`deploy`** (`<pkg>-<ver>-<rel>` equal to ports) → build the committed
  recipe as is and publish it to dist. No branch, no PR.
- **`invalid`** (exit status 2) → pass its `message=` on to the user: give
  `<pkg>` or `<pkg>-<ver>` instead. Stop.
- **`new`** (`<pkg>-<ver>`, `<pkg>` only on `dorgann/<pkg>-<ver>`) → a
  draft recipe the user has reviewed (see "New packages"). Skip Step 1b
  and go to Step 2: the dispatch rebuilds that branch.
- **`No package in yacp-dev/ports matches`** (exit status 1) → if the
  user means a package that isn't in ports yet, see "New packages".

### New packages

A package not in ports yet gets a draft recipe, pushed for the user to
review on GitHub before anything is built (doc/spec.md 4.8):

1. Start from xezat's template, the one `xezat init` writes
   (`~/src/xezat/share/xezat/template/cygport.erb`; `HOMEPAGE`/`SRC_URI`
   shapes in `share/xezat/repository/*.yaml`), and fit it to the new
   source, read from the scratchpad: `SRC_DIR` if the tarball's top
   directory isn't `${P}`, the build system's cygclass, a runtime
   package named after upstream's SOVERSION with its DLL pinned
   (`usr/bin/cyg*-N.dll`), only `*_CONTENTS` the install will actually
   produce, `BUILD_REQUIRES` for what the build files need (each
   available, as in "Checking a dependency is unavailable"), and
   `LICENSE` as in "Missing LICENSE". Follow ports' style (a similar
   recipe there is the best reference). No README: xezat writes it on
   the first green build.
2. In a worktree on a new branch from master
   (`git -C ~/src/ports worktree add -b dorgann/<pkg>-<ver> ~/src/ports-wt/<pkg>-<ver> origin/master`),
   add `<pkg>/<pkg>-<ver>-1bl1.cygport`, commit it as `<pkg>-<ver>`, and
   push the branch. No PR, no dispatch.
3. Stop and give the user the compare URL
   (`https://github.com/yacp-dev/ports/compare/master...dorgann/<pkg>-<ver>`)
   with what you decided and why. Keep the worktree for review fixes.

Once the user OKs it, `/port-until-green <pkg>-<ver>` resolves to `new`
and carries on from Step 2 like any branch rebuild.

For `bump` (and `latest` carried on as one):

1. Check whether the package's updates are blocked:
   `bash scripts/check_update_blocked.sh --repo yacp-dev/dist --package <pkg>`
   (dorgann's own `scripts/`, run from the repo root). If it prints an
   Issue URL, the workflow will skip the build anyway (doc/spec.md 4.7):
   tell the user the Issue and its blocker, and stop. (`rebuild`,
   `gcc-rebuild` and `deploy` build the version already in ports, which a
   blocker doesn't affect.)
2. Look for an existing branch and PR:
   `gh api 'repos/yacp-dev/ports/branches?per_page=100' --paginate --jq '.[].name' | grep "^dorgann/<pkg>-"`
   and `gh pr list -R yacp-dev/ports --head dorgann/<pkg>-<ver>`. A branch
   for the same version is rebuilt automatically by the dispatch: skip
   Step 1b. One for a different version is worth mentioning to the user,
   but the version from the argument (or Repology) is the target.
3. No branch for this version → Step 1b before dispatching.

For `rebuild` and `gcc-rebuild`, do 2. and 3. too: a rebuild goes
through Step 1b as well.

For every mode except `deploy`, make sure `~/src/ports` exists
(`gh repo clone yacp-dev/ports ~/src/ports` if not) and
`git -C ~/src/ports fetch origin`. Don't check out branches or edit
files in `~/src/ports` itself: other sessions share it, and a `checkout`
or `reset --hard` there can wipe their work. Branch work goes in a
per-session worktree (Step 4).

**Git snapshots** (`inherit git` with a literal `GIT_REV`, versioned
`<base>+git<YYYYMMDD>`, e.g. `sfparse-0.0.0+git20251223`) take a different
path: they track upstream HEAD, not releases, so in `latest` mode skip
the Repology lookup (pass no `--version` below), and don't let the
workflow bump them. Its `Bump version` only
renames files and substitutes the version string — `GIT_REV` would stay at
the old commit, and the run would build the old source under the new
version and *succeed*, producing a wrong PR that looks right. Instead:

```bash
scripts/git_snapshot_bump.sh --package <pkg> [--version <ver>] --dry-run   # check first
scripts/git_snapshot_bump.sh --package <pkg> [--version <ver>]
```

It resolves the upstream HEAD from `GIT_URI` (GitHub only; honors
`GIT_BRANCH`), names the version from the HEAD commit's UTC committer date,
creates and pushes `dorgann/<pkg>-<ver>` with the files renamed via
dorgann's own `bump_version.sh` and `GIT_REV` updated, and prints the
branch. It does this in a new worktree, `~/src/ports-wt/<pkg>-<ver>`
(path on stderr), and leaves it there: that's the `$wt` of Step 4, where
any fix to the branch goes. If the user gave a version that doesn't match HEAD's date, it
refuses — ask which commit they meant. Then dispatch `<pkg>-<ver>`
(Step 2), but only once that branch is pushed: it's the existing branch
that makes the run a branch rebuild instead of the workflow's own bump.
Before dispatching, check the `.src.patch`
still applies to the new HEAD (shallow-clone it at `GIT_REV` and
`patch -p0 -N -f --dry-run`; git cygclass trees are `origsrc/<repo>/`, no
version in the path), and fix it on the branch first if not.

Tell the user in one line what you settled on (mode, package, version,
new vs. existing branch) before dispatching.

## Step 1b: Preflight (version updates and rebuilds without a branch)

For `bump` (and `latest` carried on as one), `rebuild` and `gcc-rebuild`
when Step 1 found no `dorgann/<pkg>-<ver>` branch; not for git
snapshots, which `git_snapshot_bump.sh` handles. The workflow's own bump
only renames files, so whatever the new version breaks in the recipe — a
patch upstream merged or that no longer applies, a SOVERSION bump, a
`PATCH_URI` pinned to the old version — costs a whole run to find out.
A rebuild keeps the source, but not the recipe's view of it: what went
stale since its last bump (unused CMake `-D` variables, a superseded
Python, a LICENSE gap) builds green, so no run says so (uvwasi-0.0.23's
`-DVERSION`, `-DWITH_SYSTEM_LIBUV` and `-DBUILD_STATIC_LIBS`). Most of
it shows without building:

```bash
scripts/preflight_bump.sh --package <pkg> --version <ver> --work <scratchpad>/<pkg>-<ver>-preflight
```

It creates the worktree `~/src/ports-wt/<pkg>-<ver>` (Step 4's `$wt`) on
a new `dorgann/<pkg>-<ver>` branch, with the same bump the workflow would
make (for a rebuild, `bump_release.sh`'s: `1bl1` → `1bl2`), committed as
`<pkg>-<ver>` but not pushed. Then it downloads the new
source and prints a report. Go through it, fixing on the branch (for a
rebuild, the source is the current one: the patches and SOVERSION are
normally fine as they are):

- **Source** — `SRC_URI didn't resolve` (a cygclass sets it, e.g.
  `inherit github`) → rerun with `--source <url>` after removing the
  worktree and branch it made. A download or `git clone` that fails,
  or an `SRC_DIR` that isn't in the tarball, means the recipe needs a
  fix for the new version (a renamed tag or tarball layout): fix
  `SRC_URI`/`GIT_TAG`/`SRC_DIR`, then go on with the rest by hand
  against that source.
- **Patches**, each in the order cygport applies them:
  - `applies` → nothing to do.
  - `ALREADY IN SOURCE` → upstream has it: drop it from `PATCH_URI`, or
    from the `.src.patch` (regenerated as in Step 4).
  - `FAILS` on a `PATCH_URI` download → usually a URL built from `${PV}`
    or a distro branch that moved on. Look for the same patch for the new
    version (`distro_patches.sh`, below); if upstream merged it, drop it.
    If it no longer exists anywhere, check whether the new source still
    needs it before dropping it.
  - `FAILS` on hunks of a `PATCH_URI` patch → same: the distro's newer
    revision of it, or drop it if upstream took it in another form (look at the
    failing hunk against the new source). Don't rebase a distro patch by
    hand into `PATCH_URI`; if it's really needed and nobody carries it for
    this version, fold it into the `.src.patch` and say so in the report.
  - `FAILS` on the `.src.patch` → rebase it as in Step 4 (".src.patch no
    longer applies"). The work dir already holds `origsrc/` (with
    `PATCH_URI` applied) and `src/` laid out the way that recipe expects;
    `src/` is unpatched where the patch failed.
  - A `note:` about hooks (`src_unpack_hook`, `DISTCLEANFILES`, ...)
    means cygport changes the tree before patching in ways the script
    doesn't reproduce: treat a `FAILS` there as a lead, not a result.
- **SOVERSION** — compare the current DLLs with what the new source sets
  (for libtool, the computed `-version-info` suffix; for CMake/meson, the
  `SOVERSION`/`soversion` value, following its variables in the build
  file). If it changed, rename the runtime `PKG_NAMES` entry and its
  `*_CONTENTS`/`*_SUMMARY` variables (the ABI bump fix in Step 4). If the
  DLL isn't pinned (`a runtime package's DLL isn't pinned`), pin it to
  `usr/bin/cyg*-N.dll` in its own commit, `<pkg>-<ver> (pin SOVERSION in
  runtime CONTENTS)`. An override in the recipe or `.src.patch` (e.g.
  `-DSOVERSION=`) where upstream now sets its own is worth dropping in
  favor of upstream's. If you can't tell the new number with confidence,
  leave the name as it is: with the DLL pinned, a wrong guess fails
  `cygport package` with "Packages are missing files", which says which
  DLL it built.
- **LICENSE** — anything `MISSING`, or a `LICENSE_URI` that isn't in the
  new source → see "Missing LICENSE" below. Each license text listed
  with `LICENSE lacks` (usually a vendored library's, under `3rdparty/`,
  `vendor/`, ...) → check whether the build compiles what it covers,
  for the options the recipe passes (`USE_VENDORED_*=OFF` and the like
  leave it out), and add its license to `LICENSE` if so, in the same
  `<pkg>-<ver> (fix LICENSE)` commit (BehaviorTree.CPP: minicoro's
  `MIT-0 OR Unlicense`, compiled since before 4.10.0, while the recipe
  said `MIT`). The gap may predate this version: what's marked `new
  since`/`changed since` arrived with it, the rest was already missing.
  A text `gone since` the current version may leave a license in
  `LICENSE` that nothing ships any more.
- **Python** — `lines naming another Python` (e.g. `python39-devel`
  while Cygwin curr's `python3-devel` pulls in `python312-devel`) →
  switch `BUILD_REQUIRES` to `python3-devel`, rename the bindings
  subpackage to the default's name (`python39-${PN}` →
  `python312-${PN}`, with its `*_CONTENTS`/`*_SUMMARY`; no `OBSOLETES`,
  the old package stays in dist) and pin its CONTENTS to
  `usr/lib/python3.N` (log4cplus in ports), in its own commit,
  `<pkg>-<ver> (switch to python3)`. A build on the old Python goes
  green, so no run would point it out (fastjet-3.5.1, yacp-dev/ports#348).
- **CMake options** — each `-D` variable listed there is one no
  `CMakeLists.txt`/`*.cmake` in the patched source names outside
  comments and `message()` calls, and no `configure_file()` header
  template (`*.h.in`, `*.h.cmake`) names at all. Before
  dropping it, grep the source for the option's stem: a name built from
  other variables (`${PROJECT_NAME}_BUILD_TESTS`) doesn't show up as a
  word. Then drop it from `CYGCMAKE_ARGS` in its own commit,
  `<pkg>-<ver> (drop unused CYGCMAKE_ARGS)`. The final word is CMake's
  own `Manually-specified variables were not used by the project`
  warning in the `cygport compile` log, which also lists cygport's
  `CMAKE_Fortran_*`/`CMAKE_LEGACY_CYGWIN_WIN32` (not the recipe's).
  It misses one only printed in the configure summary, since printing
  it reads it (uvwasi's `UVWASI_BUILD_TESTS`). (onnx's `-DONNX_BUILD_BENCHMARKS`, unread since before 1.20.1.)

Also go through "Distro patches" (under Step 2) now, so they're in the
first run rather than added after it.

Leave what only a build can show (new build dependencies, compile and
test failures) to the run: don't guess them from the source. Commit each
fix on its own, as `<pkg>-<ver> (<what>)`, then push and go to Step 2:

```bash
git -C "$wt" push -u origin dorgann/<pkg>-<ver>
```

The dispatch then finds the branch and rebuilds it. If nothing needed
fixing, push the bump commit alone: the run is the same as the
workflow's own bump. Say in one line what the preflight found and fixed
before dispatching.

## Step 2: Build

```bash
scripts/dispatch_build.sh --target <pkg>-<ver>          # bump, rebuild
scripts/dispatch_build.sh --target <pkg>-<ver>-<rel>    # gcc-rebuild, deploy
```

For `latest`, pass the version found in Step 1. A `rebuild`/`gcc-rebuild`
run creates `dorgann/<pkg>-<ver>` like a bump does, so on failure it's
fixed and re-run the same way (`<pkg>-<ver>` re-runs either); the
changelog message is decided again from the files on each run. For
`deploy`, see "Deploying" below instead of the rest of this step.

A rebuild done to fix what the packages ship, not for a new gcc
(uvwasi-0.0.23-1bl3: a broken `uvwasi.pc` and the `-devel` package's
missing `libuv-devel`), gets a changelog line saying so rather than
`Rebuild`: pass `-f changelog_message="Fix <what>"` on every dispatch,
since each run writes the README's entry anew. Keep it short, in the
style of ports' READMEs (`Fix uvwasi.pc`, `Fix *.cmake`). Fixes the
preflight makes on its own (unused `-D` variables, LICENSE) don't
change the packages and leave the message alone.

Then, using the run id it printed (wait for that output — don't guess
the id), wait for it with `scripts/wait_run.sh --run <id>` run in the
background (builds take a while). Don't use `gh run watch`: its 3-second
refresh burns through the GitHub API rate limit that concurrent sessions
share. For a `bump`, `rebuild` or `gcc-rebuild` whose branch already
existed, if its `PATCH_URI` doesn't have them yet, use the wait to go
through "Distro patches" below; its result goes onto the branch once
this run is done, whichever way it ends. One that went through Step 1b
already has them.

- **Success** → confirm the PR is ready (`gh pr view dorgann/<pkg>-<ver> -R yacp-dev/ports --json url,isDraft`),
  then check the test suite: `scripts/check_summary.sh --run <id>`.
  `cygport check` is continue-on-error, so a green run says nothing about
  it. If it reports `check: FAILED`, go to "Test suite failures" below
  before calling it done; if `check: empty`, go to "Empty test suite". Also make sure the recipe defines `LICENSE`,
  `LICENSE_SPDX` and `LICENSE_URI`; if any is missing, see "Missing
  LICENSE" below. Then look at `Audit recipe`'s `== Runtime
  requirements ==` section (`gh run view <id> -R yacp-dev/dist --log |
  grep -A8 '== Runtime requirements =='`): a `WARNING:` there means the
  README the PR carries lists no runtime requirements, or will once an
  import library's DLL can't be found -- fix it on the branch (see
  "README's runtime requirements empty" in Step 4) and re-run. A
  `.src.patch lost changes` line in the PR body (a warning from `Copy
  build results back via xezat port`) means the committed recipe no
  longer reproduces this build: move the named files' changes into a
  `PATCH_URI` patch (see "Source doesn't build on Cygwin" in Step 4)
  and re-run. A `Dependencies the build didn't find` line in the PR
  body names Cygwin packages that provide something the build looked
  for and went without (the audit's `== Dependencies the build didn't
  find ==` section says which pkg-config module or CMake package each
  is for). For each, find the lookup in the build files and what it
  gates: one that builds more of the package -- a plugin, a backend,
  a feature upstream turns on when it's found (libwebsockets 5.0.0's
  HLS plugin, with ffmpeg) -- or its tests, goes into `BUILD_REQUIRES`
  in one commit, `<pkg>-<ver> (add <what> to BUILD_REQUIRES for
  <feature>)`, then re-run. Leave out one the recipe turned off on
  purpose (a `-D...=OFF`, a `--disable-...`), one only a fallback
  probes after what it found first (`pkg_search_module(... a b)`),
  and one for an example or another OS; say which and why in the
  report. If distro
  patches are still to be added, commit them
  now and re-run before reporting. Report: PR URL, run URL, attempts,
  what you changed, the check result, the license you filled in (if
  any), the dependencies added and left out, and the distro patches
  taken and skipped, with why.
- **Failure** → Step 3. Distro patches waiting to be added go onto the
  branch with the first fix (Step 4), in their own commit.

### Distro patches

For a version update (`bump`, `latest`) and for a rebuild (`rebuild`,
`gcc-rebuild`); not for `deploy`, which doesn't touch the recipe, or git
snapshots. Debian, Fedora and Gentoo often carry fixes for the very
version being packaged — upstream backports, CVE fixes, fixes for a newer
gcc — that Cygwin needs just as much. A rebuild keeps the version but
not the distros' view of it: they may have picked up fixes since the
version was packaged, and a rebuild for a newer gcc is just when their
gcc fixes matter. Gather them:

```bash
scripts/distro_patches.sh --project <repology name> --version <ver> --out <scratchpad>/<pkg>-distro
```

`<repology name>` is the one Step 1 used (or would have). Repology only
supplies the distros' source package names: the versions are read from
each distro directly, since Repology can lag (it had Fedora at
libpciaccess 0.16 while rawhide was at 0.19). It prints, per
distro, the packaging revision it used, the lines saying how the patches
are applied (Debian `series`, Fedora spec `Patch`/`%if` lines, Gentoo
ebuild `PATCHES`), and each patch's local file and pinned URL. Nothing
listed → no distro has this version yet; move on. Read each patch (its
header, then the diff) and **skip** it when:

- **it removes tests or weakens them** — skips, deletes or disables a
  test, marks it XFAIL, lowers what it checks, or drops it from the
  suite (`skip-memory-greedy-tests`, `no-lessopen-test`, "disable
  network tests"). A longer timeout isn't a weakening, but it's a CI
  matter, not the recipe's.
- **it doesn't concern Cygwin x86_64** — another architecture or OS
  (arm, ppc, s390x, riscv, alpha, i386/32-bit, big-endian, Hurd,
  kFreeBSD), Linux-only machinery (systemd, SELinux, seccomp,
  `/proc`, glibc-only APIs, Linux headers), or the distro's own
  packaging policy (FHS paths, Debian's added man pages, branding,
  reproducible-build tweaks, unbundling, default config, hardening
  flags). Only Fedora's `%if` branches that a Cygwin build would take
  count.
- **it's already there** — the change is in the new upstream source
  (`patch -p1 -R -f --dry-run` succeeds) or already in `PATCH_URI` (a
  still-applying old-version URL of the same patch is fine as it is; one
  that fails is Step 4's business). The same fix carried by two distros
  is taken once. One the recipe's `.src.patch` already makes is *not*
  skipped: the `.src.patch` is for changes nobody else provides, so take
  the distro patch and drop the same change from the `.src.patch`
  (libsquish-1.15-1bl4: Debian's `fixup-pkgconfig.patch` for the
  `.src.patch`'s `-lsquish` hunk).

What's left is usually an upstream backport, a security fix, or a build
fix for a newer toolchain or for portability. Don't take one you can't
explain; when in doubt, skip it and say so in the report. Then check
each candidate applies, in the order cygport would apply it: extract the
new source, apply the recipe's `PATCH_URI` patches (`-N -f`, as in Step
4), then the candidates in their distro's order, then the `.src.patch`.
A candidate that doesn't apply, or that breaks the `.src.patch` other
than where the two make the same change, is reported, not rebased —
it's an extra, not the job. Where they do make the same change, remove
those lines from the `.src.patch` hunk (keep the rest of it) and check
again that it applies on top of the candidate.

Add the ones that apply to the end of `PATCH_URI` with the pinned URL the
script printed (`.../debian/<full version>/...`, Fedora's and Gentoo's
`.../<commit>/...`), not a branch URL such as `raw/rawhide/f/` that
moves on. Commit them on their own, as `<pkg>-<ver> (add distro
patches)`, with one line per patch in the body saying what it fixes. If
a later run fails because of one, drop it rather than fixing it, and say
so in the report. On a re-run of a branch whose `PATCH_URI` already
adds URLs pinned for this version to master's, this was done before;
don't repeat it. (Pinned URLs already in master's `PATCH_URI` — as a
rebuild usually has, from the version's original bump — don't count:
they're the "already there" case above, and the newer revisions may
carry more.)

### Test suite failures

The PR is already ready at this point, so this is about whether the
package actually works, not about getting it built. The diagnostic from
`check_summary.sh` shows the totals, up to 3 distinct failing tests' log blocks,
`cygcheck` of its executable, and a direct run of it. Classify by how it
failed:

| How it failed | Likely cause | What to do |
|---|---|---|
| Every test fails the same way at startup (exit 127, `Cygwin runtime failure`, `error while loading shared libraries`) | The executables can't start at all — and the packaged ones likely can't either | Read the loader message. `cygcheck` naming a DLL "not found" → the in-tree DLL's directory isn't on `PATH` in `src_test` (e.g. `PATH=${B}/src:${PATH} ninja_test`). `Invalid relocation ... doesn't fit into 32 bits` → the exe reaches into the DLL through a 32-bit pseudo-relocation, usually because the import library marks functions as DATA. Confirm before changing anything: `gh run download <id> -R yacp-dev/dist`, unpack the `-devel` tarball, and `nm usr/lib/lib<name>.dll.a | grep -c ' T '` — zero code thunks (only `__imp_`/`__nm_` symbols) confirms it. One known cause is upstream forcing `-flto` into its own compile flags (`CFLAGS+=" -fno-lto"` overrides it, since cygport's flags come later on the command line). Fix on the branch (Step 4) — this counts as an attempt. |
| Some tests fail, others pass | Real behavior differences on Cygwin, or tests that need what a CI runner lacks (network, display, root) | Read the failing block and the test's source. Fix only when the cause is clear and Cygwin-specific (the same bar as a source patch); otherwise list the failing tests and their errors in the report and leave it to the user. When the code is right and only the test's expectation is glibc-specific (e.g. getopt's wording: glibc `invalid option -- 'j'`, Cygwin `unknown option -- j`), the user prefers patching the test to accept Cygwin's output under a Cygwin check (`uname -o` = `Cygwin`) over leaving it failing. |
| Tests about file permissions/ownership fail | The CI runner's NTFS ACLs: files and dirs created without an explicit mode lose all "other" bits there (seen in the dist artifact's own tarballs: `drwxrwx---`, `-rw-r-----`) | Environmental — report it as such, don't patch. To confirm, `tar tvJf` the artifact's tarballs and look at modes of files that weren't `install -m`'d. |
| Timeout | A hanging test | Report it; mention `-f check_timeout_minutes=` if it just looks slow. |

A guess that a re-run doesn't confirm is a wrong guess: revert it on the
branch rather than leaving it in the recipe alongside the real fix.

Re-run the same target after a fix; the bot updates the same PR. Don't
disable or skip tests to make check pass — a failing test that tells the
truth is more useful than a passing one that doesn't.

### Empty test suite

`check: empty` means check passed without running a single test:
src_test printed nothing, or cygtest/ctest/meson/automake/pytest said
there were none (the reason is in parentheses). Whether that's right
depends on upstream, so look at the source before reporting it:

- Upstream has no tests (no `test`/`tests`/`t` directory, no
  `check`/`test` target, no `enable_testing()`/`add_test`, no meson
  `test()`, no pytest/unittest files) → nothing to fix; say so in the
  report.
- Upstream has tests the build doesn't reach → fix it on the branch
  (Step 4; counts as an attempt) when the fix is a recipe change: a
  configure option that turns them on (`-DBUILD_TESTING=ON`,
  `-D<PROJECT>_BUILD_TESTS=ON`, `-Dtests=true`, `--enable-tests`), or a
  src_test that runs the target upstream actually has (`make check` in
  a subdirectory, a test script). Don't add `BUILD_REQUIRES` for a
  test framework that isn't in Cygwin; report it instead.
- A recipe whose src_test is deliberately `:`, with a comment saying
  why (needs network, hangs on Cygwin), stays that way.

A re-run that turns `empty` into `FAILED` goes on to "Test suite
failures"; one that gets `passed` is done.

### Missing LICENSE

Without `LICENSE`, cygport logs `*** Warning: LICENSE not defined` at
every step, and the `Validate build via xezat` step warns `LICENSE is
not defined` / `LICENSE_URI is not defined`. Fill in whichever of the
three is missing (keep any that are already there), from the new
version's source: the tarball from `SRC_URI`, extracted into the
scratchpad. Don't let a missing license hold up a red build. If you're
committing a fix anyway (Step 4), add the license in that commit or in
one next to it. On a branch you create yourself (Step 1b, a manual bump, a
git snapshot), add it before the first dispatch. Not for `deploy`, which
doesn't touch the recipe.

`LICENSE` covers what the binary packages ship, and only that: the
files they install, and the sources compiled into their binaries. Code
the build leaves out -- a backend it doesn't enable, a vendored
library it doesn't compile, tests, examples, the build system's own
scripts -- doesn't count, whatever its license (gperftools 2.19.1:
`BSD-3-Clause`, though `vendor/aw-backtrace` carries 0BSD and GPL
headers, since it isn't built on Cygwin). Which sources were compiled
is what the debuginfo package's `usr/src/debug/<PF>/` lists (`tar tJf`
its tarball from the run's dist artifact), or, before a green run, what
the build files compile for the options the recipe passes. A vendored
library's own license text (`vendor/<lib>/LICENSE`) counts when its
sources are among them.

Work out the license from, in this order of trust:

1. The `SPDX-License-Identifier:` headers across the shipped files
   (`grep -rhoE 'SPDX-License-Identifier: [A-Za-z0-9.+-]+' . | sort | uniq -c`
   over the whole tree, then drop what only unshipped files carry).
2. A License section in the README, which often says which part is
   under which license (libqmi: library LGPL-2.1-or-later, tools
   GPL-2.0-or-later).
3. The license text files themselves (`COPYING`, `COPYING.LIB`,
   `LICENSE*`), by their headings, to tell the version apart. Use
   `-or-later` only when the headers or the README say "or (at your
   option) any later version"; otherwise use `-only`.
4. Build metadata (meson `license:`, `pyproject.toml`, `Cargo.toml`,
   `package.json`, `*.gemspec`) last: it is often vague or out of
   date (libqmi's meson.build says `'GPL2'`).

Then write it in the recipe's style, after `DESCRIPTION` and before
`BUILD_REQUIRES`, the way `libiscsi` in ports does:

```
LICENSE="GPL-2.0-or-later AND LGPL-2.1-or-later"
LICENSE_SPDX="SPDX-License-Identifier: GPL-2.0-or-later AND LGPL-2.1-or-later"
LICENSE_URI="COPYING"
```

- `LICENSE` must be a valid SPDX expression: xezat checks it with the
  `spdx` gem and logs an error if it isn't. Join licenses with `AND`
  when different parts carry different ones, and with `OR` only when
  upstream offers a choice.
- `LICENSE_SPDX` is `SPDX-License-Identifier: ` followed by the same
  expression.
- `LICENSE_URI` is one path relative to `${S}` (xezat checks that it
  exists; it can't take a list), or an `https://` URL. Use the main
  license text file: `COPYING` or `LICENSE` in most recipes. When the
  source sits in a subdirectory (`SRC_DIR`), the path is relative to
  that.

If the source contradicts itself (the headers don't match the license
file), has no license file at all, or uses a custom or non-SPDX license,
don't guess. Leave it out and tell the user what you found.

Commit as `<pkg>-<ver> (add LICENSE)` and re-run the same target.
Afterwards, check that `Validate build via xezat` no longer logs
`LICENSE`/`LICENSE_URI` warnings or errors
(`gh run view <id> -R yacp-dev/dist --log | grep -i 'licen'`), and
that `Audit recipe`'s `== LICENSE ==` section has no `WARNING:` lines;
it applies the same shipped-files rule, and says which licenses it left
out as unshipped.

### Deploying

A `deploy` run builds the recipe exactly as committed and uploads
the dist artifact, without bumping anything or touching ports. Once
`wait_run.sh` reports success, publish that artifact:

```bash
gh api repos/yacp-dev/dist/actions/runs/<id>/artifacts --jq '.artifacts[] | select(.name | endswith("-dist")) | .id'
gh workflow run publish.yml -R yacp-dev/dist -f artifact_id=<artifact id>
```

`gh workflow run` prints the publish run's URL; wait for it with
`wait_run.sh` too. Report the build run, the publish run, and the check
result (`check_summary.sh`, as above).

If the build fails, don't fix anything: the recipe is the one already
merged in ports, and a fix needs a new release. Report the failure
(Step 3's `failure_summary.sh` for the cause) and suggest
`<pkg>-<ver>` to rebuild it with the fix as the next release.

## Step 3: Investigate

```bash
scripts/failure_summary.sh --run <id> --out <scratchpad>/<pkg>
```

Read the diagnostic first: when `cygport compile` fails on undefined
autoconf macros, the workflow lists them, which is more direct than the
log. A patch that doesn't apply shows up in the `xezat prep` log as
`*** ERROR: patch <name> will not apply`; find which hunks fail by
applying it to the new source yourself in Step 4. Then grep the saved log around the failed step (`error:`,
`Error`, `undefined reference`, `not found`, `FAILED`, `Hunk`, `*** `), and
read enough context to be sure of the cause — the first error, not the
last; later ones are often fallout. Errors that were retried and recovered
from (e.g. mirror `connection error` lines in the Cygwin install step,
which then went on to succeed) are noise, not the cause — check that the
step they appear in is actually the one that failed.
Classify it, because the response differs:

| Kind | Typical signs | What to do |
|---|---|---|
| Transient | mirror `connection error`, `download error`, HTTP 5xx, runner lost | No commit. Re-dispatch as is. Doesn't count toward the attempt limit, but give up after 3 in a row and report. |
| Unavailable dependency | the new version needs a library/program (or a minimum version of one) that neither the Cygwin mirror's curr nor dist.yacp.dev provides — e.g. `Dependency "rest-1.0" not found` with only `rest-0.7` packaged, `find_package(Boost 1.70 ...)` with curr at 1.66 | **Stop the loop now**, even on the first attempt — no recipe fix can supply it. Confirm first (see "Checking a dependency is unavailable" in Step 4); a `[test]` version doesn't count. Don't work around it by patching out the check, dropping the version requirement, or disabling the feature/tests that need it — that's the user's call (avro-cpp's Boost workaround built but every test failed, yacp-dev/dist#92). Report as under "Stopping". |
| Recipe (ports) | missing header/library/program, `.src.patch` hunk fails in `xezat prep`, file list / `PKG_NAMES` mismatch after an ABI soname bump, new configure option, test-only failure | Fix on the branch (Step 4). |
| dorgann | a step in the workflow itself or `scripts/*.sh` misbehaves regardless of the recipe (e.g. a script crashes, wrong path handling, xezat invocation broken) | Don't edit dorgann — its changes affect every package, so the user wants to review them. If the bug's damage is in the branch content and can be undone there (e.g. `Bump version` mangled a file during its one-time bump; branch-rebuild runs don't re-bump), fix it on the branch like a recipe fix and carry on, then report the dorgann bug with evidence and a proposed fix at the end. If it would recur on every run, **stop** and report. |
| No branch | failure happened before `Bump version`/`Bump release` succeeded, so no branch/draft PR exists (a version update normally has its branch from Step 1b already) | If it's transient, re-dispatch. If it's the bump itself — here, or `preflight_bump.sh` failing in `bump_version.sh`/`bump_release.sh` — (e.g. the version string doesn't appear in the cygport), the fix is a manual bump: create the branch yourself from master in a worktree (as in Step 4, with `-B dorgann/<pkg>-<ver> "$wt" origin/master`) with the renamed cygport, push, then dispatch `<pkg>-<ver>` again. |

## Step 4: Fix, commit, push

Work in a worktree of your own, not in `~/src/ports` (see Step 1):

```bash
git -C ~/src/ports fetch origin
wt=~/src/ports-wt/<pkg>-<ver>
git -C ~/src/ports worktree add -B dorgann/<pkg>-<ver> "$wt" origin/dorgann/<pkg>-<ver>
cd "$wt"
```

After Step 1b (or `git_snapshot_bump.sh`), and on later attempts, the
worktree is already there; since the bot
force-pushes the branch on every run, refresh it before editing:
`git -C "$wt" fetch origin && git -C "$wt" reset --hard origin/dorgann/<pkg>-<ver>`.
Once the loop is over (success or stopping) and everything is pushed,
remove it: `git -C ~/src/ports worktree remove "$wt"`.

Edit only files under the package directory. Common fixes:

- **Missing build dependency** → add the package to `BUILD_REQUIRES`. The
  workflow installs whatever `BUILD_REQUIRES` lists (via `cygport vars`,
  see `scripts/cygport_depends.sh`) from both the Cygwin mirror and
  dist.yacp.dev, so this is the fix — not `-f cygwin_packages=`, which
  wouldn't persist into the recipe. Find the right package name by
  searching https://cygwin.com/packages/ for the missing file. If no
  package provides it (or not a new enough version), it's an unavailable
  dependency — stop (Step 3), don't keep trying.

  **Checking a dependency is unavailable.** Look in both package lists
  the workflow installs from:
  `curl -s https://mirrors.kernel.org/sourceware/cygwin/x86_64/setup.xz | xz -d`
  and `curl -s https://dist.yacp.dev/x86_64/setup.ini`. In each `@ <name>`
  stanza the first `version:` is curr; ones after `[test]` aren't
  installed. Search by the file the build wants (`.pc`, `Config.cmake`,
  header) via https://cygwin.com/packages/ too, since the package name
  may not match. Also check whether yacp-dev/ports has a recipe for it
  that just isn't published (`gh api repos/yacp-dev/ports/contents/<name>`)
  — worth saying in the report, since publishing it is then the fix.
- **Runtime dependency / `REQUIRES`** wrong → fix `REQUIRES`.
- **ABI bump** (`libfoo1.so` → `libfoo2`, file list mismatches) → rename the
  `PKG_NAMES` entry and its `*_CONTENTS`/`*_SUMMARY` variables.
- **`cygport package`: "Packages are missing files"** → first check that
  every `*_CONTENTS`/`*_SUMMARY` variable name matches its `PKG_NAMES`
  entry as cygport expands it (`${PV}`, `${PV[1]}`, ... with `-+.` turned
  into `_`; e.g. `lib${PN}_${PV}` → `libCatch2_3_16_1_CONTENTS`). A name
  that doesn't match leaves its files in no package. Only then suspect an
  actual file list change.
- **`.src.patch` no longer applies** → rebase it. On Windows this file
  comes from `cygport diff`; with no Cygwin here, reproduce its output
  with plain `diff`, matching its shape so the next `cygport diff` on
  Windows doesn't churn it. The patch is `diff -urN` between
  `origsrc/<pkg>-<ver>/` and `src/<pkg>-<ver>/` (look at its header
  lines). Download the new source tarball from `SRC_URI`, extract it twice
  into `origsrc/` and `src/` in a scratch dir, apply the old patch to `src/`
  with `patch -p0`, resolve rejects by hand (drop hunks upstream already
  merged), then regenerate with
  `command diff -urN origsrc/<pkg>-<ver> src/<pkg>-<ver> | grep -v '^diff '`
  and save it under the new name `<pkg>-<ver>-<rel>.src.patch`, removing
  the old-version patch file if one remains. Leave out generated files.
  (`command` skips a shell alias like `diff --color`; the `grep` drops the
  `diff -urN ...` line GNU diff prints per file.) A package with no
  `.src.patch` yet gets a new one the same way. The shape only has to be
  good enough for `patch -p0` to apply: once a run succeeds, `xezat port`
  replaces it with the real `cygport diff` output on the branch.
- **A `PATCH_URI` patch fails, or a bump crosses versions it was written
  for** (often Debian/Fedora patches pinned to an old version, e.g.
  `.../debian/1.0.2-3/debian/patches/...`) → for each such patch, and each
  hunk of the `.src.patch` while you're at it, establish whether it's still
  needed: is the change already in the new upstream source? Does it still
  apply? Does the distro have a newer version of the patch
  (`curl -s https://sources.debian.org/api/src/<pkg>/` lists versions)?
  Test each against the extracted new source in `PATCH_URI` order, always
  with `-N -f` — without them `patch` asks "Reversed (or previously
  applied) patch detected! Assume -R?" and, non-interactively, says yes,
  silently un-applying it:
  - `patch -p1 -N -f --dry-run` succeeds → still needed; apply it for real
    so later patches see the same tree cygport will.
  - `patch -p1 -R -f --dry-run` succeeds → already upstream; drop it. (This
    is what cygport's own "patch X already applied; skipping" means.)
  - Neither → read the patch and grep the source: upstream often merged an
    equivalent change that differs only in whitespace or context (then
    drop it), or the code moved (then rebase it into the `.src.patch`).
  Drop a patch only when upstream has it or the problem it fixed is gone,
  and say which in the commit message and the final report — the user
  wants to know why each patch went or stayed.
- **Source doesn't build on Cygwin** → patch the source the same way, add to
  the `.src.patch`. Prefer the smallest change that's clearly correct
  (a `__CYGWIN__` guard, a missing include) over disabling features.
  A change to a file `cygport diff` excludes -- in an autotools
  package `*.h.in`, `config.h` and generated files such as `configure`
  or `Makefile.in` (the list is `pkg_pkg.cygpart`'s `default_excludes`,
  plus the recipe's `DIFF_EXCLUDES`) -- goes in a patch
  file of its own in the package directory instead, listed in
  `PATCH_URI` (`git diff`-style `a/`/`b/` paths relative to `${S}`, a
  few header lines saying why). In the `.src.patch` it builds green
  once, then `xezat port` regenerates the patch without it and the
  next build fails (libquo-1.4.1: the bundled hwloc's
  `include/hwloc/autogen/config.h.in`, now `hwloc-cygwin-uint64.patch`).
- **The `.src.patch` hardcodes the package version** (e.g. a hunk setting
  `AC_INIT([foo], [1.6.0])`; the bump doesn't touch it, so it goes stale
  silently) → drop that hunk and substitute `${PV}` in `origsrc` from a
  `src_patch_hook` instead, so `cygport diff` doesn't pick it back up
  (`movit`, `portage-utils` and `libklvanc` in ports do this):
  `CYGPORT_USE_UNSTABLE_API=1`, then `cd ${origsrcdir}/${SRC_DIR}` and a
  `sed -i` on the file. Check for this on every bump, even a green one.
- **No `LICENSE` / `LICENSE_SPDX` / `LICENSE_URI` in the recipe** →
  fill them in from the source while you're on the branch (see "Missing
  LICENSE" under Step 2).
- **README's runtime requirements empty** (`Audit recipe` warns, `Update
  README via xezat` logs `which: no <dll>`) → `cygport dep` stopped at a
  DLL it couldn't find and printed nothing. Usually that's an import
  library installed next to a dlopen()ed plugin (BehaviorTree.CPP 4.10.0:
  `usr/share/behaviortree_cpp/bt_plugins/lib*_dyn.dll.a`): nothing links
  against a plugin, so remove them in `src_install` after the install
  call (`rm -f ${D}/usr/share/<dir>/*.dll.a`) rather than pointing
  `DEPS_PATH` at them. Check first that the DLL is really only loaded at
  runtime (`dlopen`/`LoadLibrary`, a plugin directory) and that no
  installed CMake/pkg-config file names the import library. A DLL other
  packages do link against belongs in `usr/bin`, with its import library
  in `usr/lib`.
- **Only `cygport check` fails** → that step doesn't block the PR; if the
  run failed anyway, look for the real failing step instead. Test suite
  failures on a green run are handled under Step 2.

Keep fixes minimal and in the style of the existing recipe. Don't
"fix" things the log doesn't show are broken.

Commit following ports' convention — `<pkg>-<ver> (fix <what>)`, e.g.
`cpu_features-0.11.0 (fix BUILD_REQUIRES)` — and push:

```bash
git commit -am "<pkg>-<ver> (fix BUILD_REQUIRES)"   # git add new files first
git push origin dorgann/<pkg>-<ver>
```

Then back to Step 2, dispatching `<pkg>-<ver>` again.

## Stopping

- **Success** → report as in Step 2.
- **5 non-transient failed attempts** (counting the first build) → stop.
- **Same error twice in a row after a fix meant for it** → step back and
  rethink rather than repeating the same fix; if you still have no new idea,
  stop.
- **dorgann-side cause, or a decision only the user can make** (which
  upstream to follow, dropping a subpackage, disabling a feature) → stop
  and ask.
- **Unavailable dependency** (Step 3), or otherwise blocked on something
  outside the recipe → stop at once, regardless of how many attempts are
  left, and report: what the new version requires (with the upstream
  build file line), what Cygwin curr and dist.yacp.dev have instead (and
  any `[test]` version), whether ports has an unpublished recipe for it,
  and the recipe changes already worked out on the branch. Then ask
  whether to skip the update.
  If the user chooses to skip the update, record it so later dispatches
  are refused: file an Issue in yacp-dev/dist labelled `update-blocked`
  whose body starts with `<!-- dorgann-meta: {"package":"<pkg>"} -->` and
  says what blocks it and how to unblock (yacp-dev/dist#91 is the
  model). Then close the draft PR, pointing it at the Issue, and delete
  the branch (`gh api -X DELETE
  repos/yacp-dev/ports/git/refs/heads/dorgann/<pkg>-<ver>`, plus the
  local one in `~/src/ports`): the closed PR keeps its diff.

When stopping without success, report: the branch and draft PR URL, the
last run URL, each attempt's error and what you tried, your best current
diagnosis, and what you'd try next. Leave the branch in a pushed state
— don't leave local-only changes.
