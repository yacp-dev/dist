---
name: port-until-green
description: Drive a yacp-dev/ports package update to a passing PR. Dispatches yacp-dev/dist's build-package workflow for the named package (creating the dorgann/<pkg>-<ver> branch, or rebuilding the one already there), and when the Windows/Cygwin build fails, investigates the log, fixes the recipe on that branch, commits, pushes and re-runs until it passes. Takes one argument: <pkg> (update to Repology's newest), <pkg>-<ver> (update to that version, or bump the release if it's the current one), or <pkg>-<ver>-<rel> (current release: build and deploy to dist; next release: gcc rebuild). Use this whenever the user names a ports/yacp package and wants it bumped, built, its PR made green, or its draft dorgann PR / build-failed Issue fixed — e.g. "/port-until-green knot", "ngtcp2 の PR 作って", "Catch2 のビルド直して" — even if they don't say "skill" or "workflow".
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
also accepts `catch2`).

## How the pieces fit (read once)

The build only runs on dorgann's `windows-latest` CI (`.github/workflows/build-package.yml`
in this repo, yacp-dev/dist). There's no local Cygwin, so every build
attempt is a workflow run, ~5–30 min each. Key behaviors:

- Dispatching with `package` + `version` bumps the recipe. On success the
  workflow opens the PR on `dorgann/<pkg>-<ver>`; on failure it pushes the
  same branch as a **draft** PR and files a `build-failed` Issue in
  yacp-dev/dist — as long as the bump itself succeeded.
- If `dorgann/<pkg>-<ver>` already exists, a `package`+`version` dispatch
  automatically switches to branch-rebuild mode: it overlays the branch's
  changes onto master and rebuilds. Passing `branch=dorgann/<pkg>-<ver>` is
  equivalent. So after pushing a fix, just dispatch again.
- **The bot rewrites the branch on every run** (peter-evans/create-pull-request
  squashes everything into one `<pkg>-<ver>` commit and force-pushes). Your
  local branch is therefore stale after each run — always
  `git fetch && git reset --hard origin/<branch>` before editing, or your
  push will be rejected or will clobber the bot's commit.
- See `doc/spec.md` 4.5–4.6 for the full design if something here surprises you.

Helpers bundled with this skill (paths relative to this SKILL.md):

- `scripts/resolve_target.sh <arg>` — splits the argument into package,
  version and release, compares them with the `.cygport` on ports'
  master, and prints `key=value` lines including `mode=` (Step 1).
- `scripts/dispatch_build.sh --package P (--version V | --branch B) [-f key=val ...]`
  — dispatches and prints `<run id> <run url>`.
- `scripts/wait_run.sh --run ID [--interval SECS]` — waits for a run of
  either workflow
  (one API call every 90 s by default), prints `<conclusion> <run url>`,
  and exits 0 only on success.
- `scripts/failure_summary.sh --run ID --package P --out DIR` — failed step
  names, the open `build-failed` Issue body (where patch/macro diagnostics
  land), and the full failed log saved to `DIR` for grepping.
- `scripts/check_summary.sh --run ID` — whether `cygport check` passed,
  and its diagnostic if not (Step 2).
- `scripts/git_snapshot_bump.sh --package P [--version V] [--dry-run]` —
  bumps a git-snapshot package to upstream HEAD on its own branch (see
  Step 1).

## Step 1: Resolve the argument

```bash
scripts/resolve_target.sh <arg>
```

It finds the package as the longest ports directory name the argument
starts with (package names can contain dashes), then splits the rest into
`<ver>[-<rel>]`. Act on its `mode=`:

- **`latest`** (`<pkg>`) → find the newest upstream version on Repology:
  `curl -s https://repology.org/api/v1/project/<name>` and take a
  `"status": "newest"` entry's version (the project name may need
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
  requirements, else `Rebuild`.
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
   for the same version is rebuilt automatically by the dispatch. One for
   a different version is worth mentioning to the user, but the version
   from the argument (or Repology) is the target.

For every mode except `deploy`, make sure `~/src/ports` exists
(`gh repo clone yacp-dev/ports ~/src/ports` if not) and
`git -C ~/src/ports fetch origin`.

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
branch. If the user gave a version that doesn't match HEAD's date, it
refuses — ask which commit they meant. Then dispatch with `--branch`
(Step 2), never `--version`. Before dispatching, check the `.src.patch`
still applies to the new HEAD (shallow-clone it at `GIT_REV` and
`patch -p0 -N -f --dry-run`; git cygclass trees are `origsrc/<repo>/`, no
version in the path), and fix it on the branch first if not.

Tell the user in one line what you settled on (mode, package, version,
new vs. existing branch) before dispatching.

## Step 2: Build

```bash
scripts/dispatch_build.sh --package <pkg> --version <ver>        # bump
scripts/dispatch_build.sh --package <pkg> -f rebuild=true        # rebuild, gcc-rebuild
scripts/dispatch_build.sh --package <pkg> -f validate_only=true  # deploy
```

A `rebuild`/`gcc-rebuild` run creates `dorgann/<pkg>-<ver>` like a bump
does, so on failure it's fixed and re-run with `--branch` the same way;
the changelog message is decided again from the files on each run. For
`deploy`, see "Deploying" below instead of the rest of this step.

Then, using the run id it printed (wait for that output — don't guess
the id), wait for it with `scripts/wait_run.sh --run <id>` run in the
background (builds take a while). Don't use `gh run watch`: its 3-second
refresh burns through the GitHub API rate limit that concurrent sessions
share.

- **Success** → confirm the PR is ready (`gh pr view dorgann/<pkg>-<ver> -R yacp-dev/ports --json url,isDraft`),
  then check the test suite: `scripts/check_summary.sh --run <id>`.
  `cygport check` is continue-on-error, so a green run says nothing about
  it. If it reports `check: FAILED`, go to "Test suite failures" below
  before calling it done. Report: PR URL, run URL, attempts, what you
  changed, and the check result.
- **Failure** → Step 3.

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

Re-run with `--branch` after a fix; the bot updates the same PR. Don't
disable or skip tests to make check pass — a failing test that tells the
truth is more useful than a passing one that doesn't.

### Deploying

A `validate_only` run builds the recipe exactly as committed and uploads
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
scripts/failure_summary.sh --run <id> --package <pkg> --out <scratchpad>/<pkg>
```

Read the Issue body first: when `xezat prep` or `cygport compile` fails, the
workflow's diagnose steps put a focused diagnostic there (patch dry-runs at
every `-p` level, undefined autoconf macros), which is usually more direct
than the log. For a `PATCH_URI` failure it lists every patch as applies /
already applied (upstream has it, droppable) / will not apply, replayed
against a fresh unpack — use that as your starting point for the
still-needed check in Step 4. (Runs from before 2026-10-18 only diagnosed
the `.src.patch`; there, the log's `*** ERROR: patch <name> will not
apply` line is the cause.) Then grep the saved log around the failed step (`error:`,
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
| No branch | failure happened before `Bump version` succeeded, so no branch/draft PR exists | If it's transient, re-dispatch. If it's the bump itself (e.g. the version string doesn't appear in the cygport), the fix is a manual bump: create the branch yourself from master in `~/src/ports` with the renamed cygport, push, then dispatch with `--branch`. |

## Step 4: Fix, commit, push

```bash
cd ~/src/ports
git fetch origin
git checkout -B dorgann/<pkg>-<ver> origin/dorgann/<pkg>-<ver>
```

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
- **The `.src.patch` hardcodes the package version** (e.g. a hunk setting
  `AC_INIT([foo], [1.6.0])`; the bump doesn't touch it, so it goes stale
  silently) → drop that hunk and substitute `${PV}` in `origsrc` from a
  `src_patch_hook` instead, so `cygport diff` doesn't pick it back up
  (`movit`, `portage-utils` and `libklvanc` in ports do this):
  `CYGPORT_USE_UNSTABLE_API=1`, then `cd ${origsrcdir}/${SRC_DIR}` and a
  `sed -i` on the file. Check for this on every bump, even a green one.
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

Then back to Step 2 with `--branch dorgann/<pkg>-<ver>`.

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
  model). Then close the draft PR and the `build-failed` Issue, pointing
  both at it.

When stopping without success, report: the branch and draft PR URL, the
last run URL, each attempt's error and what you tried, your best current
diagnosis, and what you'd try next. Leave the branch in a pushed state
— don't leave local-only changes.
