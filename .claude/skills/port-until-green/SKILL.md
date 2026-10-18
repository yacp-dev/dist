---
name: port-until-green
description: Drive a yacp-dev/ports package update to a passing PR. Dispatches yacp-dev/dist's build-package workflow for the named package (creating the dorgann/<pkg>-<ver> branch, or rebuilding the one already there), and when the Windows/Cygwin build fails, investigates the log, fixes the recipe on that branch, commits, pushes and re-runs until it passes. Use this whenever the user names a ports/yacp package and wants it bumped, built, its PR made green, or its draft dorgann PR / build-failed Issue fixed — e.g. "/port-until-green knot", "ngtcp2 の PR 作って", "Catch2 のビルド直して" — even if they don't say "skill" or "workflow".
argument-hint: <package> [version]
---

# port-until-green

Get one package in [yacp-dev/ports](https://github.com/yacp-dev/ports) to a
ready (non-draft) PR, by looping: build on dorgann's CI → read the failure →
fix the recipe on the branch → build again.

Arguments: `<package> [version]`. `<package>` is the package's directory
name in ports (case matters: `Catch2`, not `catch2`).

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

- `scripts/dispatch_build.sh --package P (--version V | --branch B) [-f key=val ...]`
  — dispatches and prints `<run id> <run url>`.
- `scripts/failure_summary.sh --run ID --package P --out DIR` — failed step
  names, the open `build-failed` Issue body (where patch/macro diagnostics
  land), and the full failed log saved to `DIR` for grepping.

## Step 1: Work out version and branch

1. If ports already has a `dorgann/<pkg>-*` branch, that's the target —
   unless the user gave a different version:
   `gh api 'repos/yacp-dev/ports/branches?per_page=100' --paginate --jq '.[].name' | grep "^dorgann/<pkg>-"`.
   Also check `gh pr list -R yacp-dev/ports --head dorgann/<pkg>-<ver>` for
   the existing PR.
2. Otherwise, if no version was given, determine the latest upstream one:
   - Current version: the `.cygport` filename in ports
     (`gh api repos/yacp-dev/ports/contents/<pkg> --jq '.[].name'`,
     `<pkg>-<ver>-<rel>.cygport`). Read the file for `HOMEPAGE`/`SRC_URI`.
   - If those point at `github.com/<owner>/<repo>`: `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name`,
     falling back to `.../tags`. Normalize the tag (`v1.2.3` → `1.2.3`,
     `foo-1.2.3` → `1.2.3`, `1_2_3` → `1.2.3` if that's how the cygport spells it).
   - Cross-check with Repology: `curl -s https://repology.org/api/v1/project/<name>`
     and take the `newest` entry's version (the project name may need
     lowercasing or a prefix like `python:`).
   - If the latest equals the current version, tell the user it's already
     up to date and stop. If GitHub and Repology disagree, or the
     "newest" looks like a distro fork/prerelease, ask the user instead of
     guessing — a wrong version means a wrong PR.
3. Make sure `~/src/ports` exists (`gh repo clone yacp-dev/ports ~/src/ports`
   if not) and `git -C ~/src/ports fetch origin`.

Tell the user in one line what you settled on (package, version, new vs.
existing branch) before dispatching.

## Step 2: Build

```bash
scripts/dispatch_build.sh --package <pkg> --version <ver>
```

Then wait for it with `gh run watch <id> -R yacp-dev/dist --exit-status`
run in the background (builds take a while; don't poll in a tight loop).

- **Success** → confirm the PR is ready (`gh pr view dorgann/<pkg>-<ver> -R yacp-dev/ports --json url,isDraft`),
  and report: PR URL, run URL, attempts, and what you changed. Done.
- **Failure** → Step 3.

## Step 3: Investigate

```bash
scripts/failure_summary.sh --run <id> --package <pkg> --out <scratchpad>/<pkg>
```

Read the Issue body first: when `xezat prep` or `cygport compile` fails, the
workflow's diagnose steps put a focused diagnostic there (patch dry-runs at
every `-p` level, undefined autoconf macros), which is usually more direct
than the log. Then grep the saved log around the failed step (`error:`,
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
  searching https://cygwin.com/packages/ for the missing file. If the
  dependency is another ports package that isn't published on
  dist.yacp.dev, stop and report it.
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
  merged), then regenerate with `diff -urN origsrc/<pkg>-<ver> src/<pkg>-<ver>`
  and save it under the new name `<pkg>-<ver>-<rel>.src.patch`, removing
  the old-version patch file if one remains. Leave out generated files.
- **A `PATCH_URI` patch fails, or a bump crosses versions it was written
  for** (often Debian/Fedora patches pinned to an old version, e.g.
  `.../debian/1.0.2-3/debian/patches/...`) → for each such patch, and each
  hunk of the `.src.patch` while you're at it, establish whether it's still
  needed: is the change already in the new upstream source? Does it still
  apply (`patch -p1 --dry-run` against the extracted source)? Does the
  distro have a newer version of the patch
  (`curl -s https://sources.debian.org/api/src/<pkg>/` lists versions)?
  Drop a patch only when upstream has it or the problem it fixed is gone,
  and say which in the commit message and the final report — the user
  wants to know why each patch went or stayed.
- **Source doesn't build on Cygwin** → patch the source the same way, add to
  the `.src.patch`. Prefer the smallest change that's clearly correct
  (a `__CYGWIN__` guard, a missing include) over disabling features.
- **Only `cygport check` fails** → that step doesn't block the PR; if the
  run failed anyway, look for the real failing step instead.

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

When stopping without success, report: the branch and draft PR URL, the
last run URL, each attempt's error and what you tried, your best current
diagnosis, and what you'd try next. Leave the branch in a pushed state
— don't leave local-only changes.
