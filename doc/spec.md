# Cygwin Package Auto-Maintenance System — Specification

## 1. Purpose

For the package recipes managed in [yacp](https://github.com/yacp-dev/ports), automatically detect upstream version updates and automate everything from updating the cygport file, building, and creating a PR against yacp.

## 2. Repository Layout

Without using external storage, a database, or any paid service, the whole system is self-contained in **a single public git repository**.

| Repository | Role |
|---|---|
| `yacp-dev/ports` (existing) | The package recipes themselves. The target that receives PRs from the automation system. |
| A new public repo (`dorgann`) | The automation system itself. Consists of two branches: `main` and `gh-pages`. |

### 2.1 `main` branch

- The list of monitored packages (`packages.yml`)
- The scripts that implement update checking, building, and PR creation
- The GitHub Actions workflow definitions (`.github/workflows/`) that invoke them

`packages.yml` is **not** a state file — it is simply an array of monitored package names (details in 4.2.2). The "currently packaged version" is fetched from yacp itself, and the "record of build failures" is fetched from Issues, each time they're needed, so there's no need for `packages.yml` to duplicate that state.

### 2.2 `gh-pages` branch

- A Cygwin-compatible binary repository (in `setup.ini` format) for distributing devel packages that are only available through yacp
- Configured as a GitHub Pages publishing source, used as an additional site (User URL) for `setup-x86_64.exe` at build time

## 3. Distributing devel packages (GitHub Pages)

### 3.1 Why GitHub Pages

The `install:` line in `setup.ini` specifies files as a **relative path** from the site's base URL (e.g. `x86_64/release/<pkg>/<pkg>-<version>.tar.xz`), and setup.exe walks that directory hierarchy as-is to download files ([setup.ini documentation](https://sourceware.org/cygwin-apps/setup.ini.html)).

GitHub Releases asset URLs follow a fixed format, `.../releases/download/<tag>/<filename>`, which can't carry a sub-path, so that directory hierarchy can't be reproduced there — hence it was rejected. GitHub Pages can statically serve a repository's contents including its directory structure, which meets this requirement.

The same technique (build packages in CI → generate repository metadata → publish via GitHub Pages) has precedent in APT/YUM repositories (e.g. [noports-apt](https://github.com/atsign-foundation/noports-apt)), so it is a technically established pattern.

### 3.2 Setup procedure

1. Place build artifacts using the naming convention `x86_64/release/<pkg>/<pkg>-<version>-<release>.tar.xz` plus `.hint` ([Cygwin package files](https://cygwin.com/packaging-package-files.html)).
2. Use `mksetupini` from `calm` (`pip3 install git+https://cygwin.com/git/cygwin-apps/calm.git`) to generate `setup.ini`/`setup.bz2`/`setup.xz`. Since this isn't a repository with a full package set (it's an overlay), pass `--disable-check=missing-required-package,missing-depended-package` ([Cygwin Package Server](https://cygwin.com/package-server.html)).
3. Push the result to the `gh-pages` branch and publish it via GitHub Pages.
4. In the build job, specify it as an additional site with `setup-x86_64.exe -P <package> --site <official mirror> --site <Pages URL>` to resolve dependencies.

> **Operational note**: step 3, "publish to gh-pages," is **done manually** for now and is not automated. There is no design where all dist artifacts are automatically pushed to gh-pages on a successful build.

### 3.3 Capacity, bandwidth, and operational constraints

- GitHub Pages: free for public repos. The published site has a 1GB size limit, with a soft bandwidth limit of 100GB/month. The default Jekyll build has a soft limit of "10 builds/hour," but **this doesn't apply when publishing via a custom GitHub Actions workflow** ([GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)).
- Devel packages always keep **a single generation (`curr` only)**. When a new version is added, the old version's files are deleted (e.g. adding `libhoge-2.0` removes `libhoge-1.0`). The full yacp package set is never duplicated.

**On `gh-pages` history management**: If binaries are only ever appended and never overwritten, git stores content by blob, so history has almost no effect on repository size. Size becomes a problem when files are *deleted* — under normal commit history, blobs for deleted files are still referenced from past commits and never get garbage-collected.

However, this does not affect GitHub Pages' **1GB limit on the published site itself** (i.e. the actual size of the tree at HEAD) — the published size correctly shrinks once a deletion commit is made. What it does affect is the looser, softer guideline of a "recommended 1GB" for the *source* repository ([GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)).

As noted above, this repository's operational pattern is "adding a new version almost always comes paired with deleting the old one" (keeping only one generation), so deletion isn't an exceptional event — it's business as usual. Since publishing to gh-pages is already a manual, irregular activity (4.4), the simplest approach that doesn't add operational overhead is to **rebuild the `gh-pages` branch down to a single commit and force-push it every time that manual step happens**. Since pushes aren't automated or frequent, rewriting history via force-push isn't a burden.

## 4. Processing Flow

### 4.1 Overview

```
[daily cron]
  └─ check-updates job (one job, sequential)
       - Check versions via Repology etc. for every package in packages.yml
       - Compare recorded failures (Issues) against the latest version to decide whether a retry is needed
       - Output the JSON list of "packages that need a build this time"
  └─ build job (matrix, only starts if check-updates' output is non-empty)
       - Runs as an independent job per package, in parallel (fail-fast: false)
       - Updates the cygport file, builds, uploads artifacts
       - On success: create a PR against yacp / close the corresponding Issue if any (reflecting the devel package to gh-pages is NOT automated — it's manual)
       - On failure: file an Issue
```

### 4.2 Daily update check (check-updates)

- Triggered once a day via `schedule: cron`.
- For each package in `packages.yml`, decide in this order:
  1. Fetch the **current version** from yacp itself (4.2.2).
  2. Fetch the **latest version** from Repology / the GitHub Releases API (4.2.1).
  3. If current == latest, **no update** (skip).
  4. If current < latest, and there is already an open failure Issue (4.5) for that latest version, **skip** (already failed against the same version last time). Otherwise, **mark it for build**.
- Output: a JSON array of package names to build. An empty array on days with no updates.

#### 4.2.1 How to check upstream versions (finalized)

**Repology is the baseline source, and for packages hosted on GitHub, the GitHub Releases API is used in addition.**

- **Repology** ([API](https://repology.org/api)): The common, primary source of truth across all packages. Rate limit is 1 req/sec; bulk usage beyond roughly 1,000 req/day is discouraged (beyond that, using the database dump instead of the API is recommended). This check runs sequentially, with spacing, inside a single job.
- **GitHub Releases API** ([REST API endpoints for releases](https://docs.github.com/en/rest/releases/releases)): Whether upstream is hosted on GitHub is not recorded manually in `packages.yml` — instead, the `HOMEPAGE`/`SRC_URI` fields of the package's cygport file in yacp are parsed every time to auto-detect a `github.com/<owner>/<repo>` pattern (this is read from the same file fetched in 4.2.2, so no extra repository access is needed). Only when detected, the following are additionally queried:
  - `GET /repos/{owner}/{repo}/releases/latest` (returns the latest non-draft, non-prerelease release) is tried first.
  - `GET /repos/{owner}/{repo}/tags` is a fallback for projects that only use tags and never publish releases.
  - Since `tag_name` often has a prefix like `v1.2.3`, it is normalized before comparison, matching cygport's naming convention ([Package naming scheme](https://cygwin.com/packaging-package-files.html#naming)).
  - Requests are authenticated with `GITHUB_TOKEN` on GitHub Actions. When authenticated, `GITHUB_TOKEN`'s rate limit is **1,000 req/hour per repository** ([Rate limits for the REST API](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api#primary-rate-limit-for-github_token-in-github-actions)), so hitting that limit with one run per day is essentially inconceivable.
  - There can be cases where `HOMEPAGE` points to a plain project site rather than GitHub and auto-detection fails, but that just falls back to judging by Repology alone, so it isn't fatal.
- **When results from both sources are available**: the GitHub Releases API result is treated as the primary signal, with Repology used as a cross-check. If they agree, proceed as normal; **if they disagree, don't auto-decide — surface it via an Issue etc. and require manual confirmation** (this is aimed at reducing false positives from Repology misclassification or sync lag). Packages hosted somewhere other than GitHub continue to be judged by Repology alone.

#### 4.2.2 `packages.yml` format and how the current version is obtained (finalized)

`packages.yml` is a **simple array** of monitored package names.

```yaml
- foo
- bar
- baz
```

The "currently packaged version" is not stored in `packages.yml`; it's fetched each time from the corresponding package's cygport file in yacp itself (`yacp-dev/ports`), via the GitHub Contents API or a lightweight checkout, parsing variables such as `VERSION=`. Since `HOMEPAGE`/`SRC_URI` can be read at the same time, the GitHub auto-detection from 4.2.1 happens at this same point.

This way, `packages.yml` only needs to be managed via PRs for adding/removing packages, and never needs to duplicate state like version info or Issue numbers (all state lives in yacp itself and in Issues).

#### 4.2.3 Deliberately pausing version tracking (finalized)

Because Repology aggregates package information across multiple distributions, if any one distribution adopts its own forked version numbering, that can be mistakenly judged as "the latest version." In such cases, it's fine to simply **comment out** the relevant line in `packages.yml` in YAML, temporarily pausing monitoring for that package.

```yaml
- foo
# - bar  # v2.1 is a distro-specific fork's version number, not upstream. Commented out pending a decision.
- baz
```

This has the side effect of stopping monitoring for the whole package (a real new version wouldn't be detected either), but that's accepted. The reasoning: by the time an official distribution has adopted a forked version, the upstream project itself is likely already inactive, and in that case the right move isn't to ignore it but to consider switching to follow the fork instead. In other words, this isn't "ignore the false positive and leave it," but rather "pause until a human decides whether to switch upstream to the fork" — and until that decision is made, a simple comment-out is sufficient. A finer-grained, per-version ignore mechanism (e.g. Issue-based) is not being introduced at this time.

### 4.3 Build (matrix)

- `needs.check-updates.outputs.packages` is expanded into `strategy.matrix.package` for parallel jobs.
- `fail-fast: false` ensures one package's failure doesn't affect the others.
- `if: needs.check-updates.outputs.packages != '[]'` guards against starting the job at all on days with zero updates (an empty matrix would otherwise error out — this guard is required). By rejecting the empty-array case, there is never a "no-op run" that iterates over the full monitored set every day. Within a single daily workflow run, the number of jobs dynamically scales with however many packages actually had updates.
- `max-parallel` is tuned with the free tier's concurrent-job cap in mind (20 across the whole account, [Actions limits](https://docs.github.com/en/actions/reference/limits)) — Windows-minute billing isn't a concern since this is a public repo (see chapter 6).
- Builds run on a Windows runner (`windows-latest`) using cygport + xezat. The per-package pipeline validated in Step 1 (`.github/workflows/build-package.yml`, `scripts/*.sh`) is:

  1. **Configure cygport** (`configure_cygport.sh`) — writes `$HOME/.cygportrc` with `DISTDIR` pointed outside the package directory. Without this, `cygport fetch` leaves the downloaded source tarball sitting right next to the tracked `.cygport` file (cygport's own default when `DISTDIR` is unset), indistinguishable from a real source-controlled file to a later `git add`.
  2. **Bump version** (`bump_version.sh`) — renames `<PN>-<oldPV>-<oldPR>.cygport` (and any sibling file sharing that versioned basename, e.g. a `.src.patch`) to `<PN>-<newPV>-1bl1`, and does a best-effort literal-string substitution of the old bare version inside each renamed file's content (for `SRC_URI` etc. that hardcode the version instead of referencing `${PV}`). This is a plain filesystem rename, not `git mv` — the new names are untracked until a later `git add`. xezat has no command that performs this step itself; it only rewrites README/changelog after the fact (see step 6).
  3. **Determine extra build dependencies** (`cygport_depends.sh`) — asks cygport itself (`cygport <file> vars ...`) for `BUILD_REQUIRES`/`DEPEND`/`INHERITED`, mirroring cygwin/scallywag's own CI logic, and installs those on top of a fixed base toolchain (cygport itself, plus a compiler, since cygport doesn't declare one as a dependency). Every `cygwin-install-action` call in this job also adds dorgann's own gh-pages (chapter 3) as an extra site alongside the official mirror, so a build can depend on another package that's only ever been published there.
  4. **xezat prep** (`xezat_prep.sh`) — `cygport fetch` + `cygport prep`, plus a copy of the package directory's README into the build tree (`$C`, which cygport defines as `${S}/CYGWIN-PATCHES`) that xezat itself does. That copy is what step 6 later reads and appends a changelog entry to.
  5. **cygport compile / check / install / package** (`cygport_build.sh`, one Actions step each) — the rest of the normal cygport build. `check` (the package's own test suite, where it has one) is deliberately non-fatal: `continue-on-error: true` plus a `timeout-minutes` bound (the `check_timeout_minutes` input, default 10) so a hang doesn't hold the job hostage, since a failing or hanging test suite says something worth knowing about the package but isn't reason enough to withhold the PR/artifact over, unlike an actual compile/install/package failure. `install` also runs `postinst` internally (cygport's own `install` case runs `src_install && __src_postinst`), which is what first embeds `$C/README` into the package as `/usr/share/doc/Cygwin/<PN>.README`.
  6. **Validate build via xezat** (`xezat_validate.sh`) — `xezat validate`, run with `--ignore` (the only finding it turns into a hard failure rather than a logged warning is an SSL error during its `HOMEPAGE` livecheck, which is a network condition unrelated to the package). Checks category/homepage/license against xezat's known-good lists, `BUILD_REQUIRES` against packages actually installed, and any installed `.pc`/`*-config` files.
  7. **Update README via xezat** (`xezat_bump.sh`) — `xezat bump`, which regenerates `$C/README` with a new changelog entry. It only ever writes to that build-tree copy, never to the package directory's tracked file.
  8. **cygport postinst / package (again)** (`cygport_build.sh --step postinst`, then `--step package`) — step 5's `install` already ran postinst once, but at that point `$C/README` was still the pre-bump copy from step 4. Re-running postinst re-embeds the now-bumped README into `$D`, and package has to be re-run too so the actual dist archive picks up that change.
  9. **Copy build results back via xezat port** (`xezat_port.sh`) — `xezat port` copies the cygport file, README, and `.src.patch` from the build tree into `<portdir>/<PN>/`. Since the cygport file's own build-tree location (`$top`) is the *same* directory this needs to copy into (yacp keeps the `.cygport` directly in the package directory, not in a separate staging tree), pointing `--portdir` there directly would make `xezat port` try to copy a file onto itself and fail (`FileUtils.cp` refuses same-file copies) — so it ports into a scratch directory instead, and only README/`.src.patch` are copied back out of it. Also requires an (otherwise-unused) `$HOME/.xezat/config.yml` to exist, since `xezat port` unconditionally tries to load its config file before even looking at `--portdir`.
  10. **Show diff** (`git -C yacp add -A -- <pkg> ...` then `git diff --cached`) — stages before diffing, since a plain unstaged `git diff` never shows the untracked new `.cygport`/`.src.patch` filenames step 2's rename produced. The cygport build tree (`<PN>-<PV>-<PR>.<arch>/`, which lives inside the package directory too) and xezat's own variable-extraction cache (`<cygport-basename>.<uname -m>.yml`) are excluded via pathspec — the former isn't meant to be committed and contains a symlink Windows Git can't index, which would otherwise abort the whole `git add`.
  11. **Upload dist artifact** — the packaged `.tar.xz`/`.hint` from step 8.

### 4.4 On success

- The updated cygport file, patches, and README are turned into a PR against yacp (using `peter-evans/create-pull-request`).
- Build artifacts (dist) are uploaded as an Actions artifact, downloadable from the run page. **Retention stays at the repository's default (90 days)** and is not changed.
- The **decision** of whether to publish something as a devel package on gh-pages (chapter 3) is not automated. If the decision is made to publish, the **actual work** happens via the manual `workflow_dispatch` workflow described in 4.4.2 (build artifacts are not mechanically funneled to gh-pages for everything).
- If there's an open failure Issue for the same package, it is closed.

Whether the PR is merged/rejected has nothing to do with whether the package gets published as a devel package on gh-pages (merging into yacp doesn't necessarily mean it should be published on gh-pages, and conversely a still-open PR might get its contents checked and published anyway). So the PR carries no gh-pages-publishing information. The 4.4.2 workflow is self-contained, looking only at `dorgann`'s own Actions artifacts.

#### 4.4.1 Permissions required to create a PR against yacp (finalized)

`peter-evans/create-pull-request` creates a branch against whichever repository was `actions/checkout`'d as of that step. By switching the checkout target from `dorgann` to yacp, both the branch and the PR end up created in yacp ([concepts-guidelines.md](https://github.com/peter-evans/create-pull-request/blob/main/docs/concepts-guidelines.md#creating-pull-requests-in-a-remote-repository)).

```yaml
- uses: actions/checkout@v6
  with:
    token: ${{ steps.app-token.outputs.token }}
    repository: yacp-dev/ports

# cygport update etc. happens here

- uses: peter-evans/create-pull-request@v8
  with:
    token: ${{ steps.app-token.outputs.token }}
    author: <app-slug>[bot] <<bot-user-id>+<app-slug>[bot]@users.noreply.github.com>
    committer: <app-slug>[bot] <<bot-user-id>+<app-slug>[bot]@users.noreply.github.com>
```

`dorgann`'s default `GITHUB_TOKEN` is only scoped to `dorgann`, so it cannot push to yacp as-is. Instead, a GitHub App (installed on yacp-dev, with **`contents: write` / `pull-requests: write`**) mints an installation token via `actions/create-github-app-token`, from the org secrets `DORGANN_APP_ID` / `DORGANN_APP_PRIVATE_KEY`, and that token is passed explicitly to both the checkout and create-pull-request steps. An App is used rather than a fine-grained PAT so the branches/PRs (and, via explicit `author`/`committer` — create-pull-request otherwise defaults `author` to `github.actor` — the commits too) are attributed to the App's `[bot]` account instead of showing up in a human's own activity. Installation tokens expire after 1 hour, so a fresh one is minted again right before the PR steps rather than reusing the one from the start of a long Windows build. The same App also serves yacp's `distribute.yml` for the reverse direction (`repository_dispatch` to dorgann, which needs `contents: write` on yacp-dev/dist). Since both repos are owned by the same account, there's no need to go through a fork (`push-to-fork`) — branches can be pushed directly to yacp.

Note also that PRs created with the default `GITHUB_TOKEN` cannot trigger other workflows on `pull_request`/`push` (e.g. yacp's own CI checks) by design ([Triggering further workflow runs](https://github.com/peter-evans/create-pull-request/blob/main/docs/concepts-guidelines.md#triggering-further-workflow-runs)), which is another reason a PAT/App token is the right design here.

#### 4.4.2 Publishing to gh-pages (semi-automated, finalized)

The **decision** of whether to publish something as a devel package on gh-pages is made by a human, but **once that decision is made, the work (from fetching the artifact through to the force-push) is automated via `workflow_dispatch`**. This is self-contained around `dorgann`'s own Actions artifacts, independent of yacp's PR state (merged or not). Nothing is added on the yacp side.

- The only input parameter is the **artifact ID** (`artifact_id`). Opening the download link for the target dist artifact on `dorgann`'s Actions run page reveals the artifact ID in the URL, which is passed in as-is. The package name and version can be read from the artifact's contents (filenames follow the 3.2 naming convention `<package>-<version>-<release>.tar.xz`), so there's no need to input them separately.

```yaml
on:
  workflow_dispatch:
    inputs:
      artifact_id:
        description: "ID of the dist artifact to publish to gh-pages"
        required: true
        type: string
```

- What the workflow does:
  1. Uses `artifact_id` to fetch the dist artifact from `dorgann`'s own Actions artifact API (`GET /repos/{owner}/{repo}/actions/artifacts/{artifact_id}/zip`).
  2. Reads the package name and version from the extracted filenames, and replaces the contents of `x86_64/release/<package>/` with the new version's files (per the single-generation rule in 3.3, the existing old version is deleted).
  3. Regenerates `setup.ini` with `mksetupini` (3.2).
  4. Rebuilds the `gh-pages` branch down to a single commit and force-pushes it (3.3).
- **Caveat**: since dist artifacts expire under the default 90-day retention (4.4), running this workflow more than 90 days after the build means the artifact will no longer be found. In that case, the package needs to be rebuilt.

### 4.5 On failure (finalized)

An Issue is filed, made up of two parts:

**Label**: tagged `build-failed`, so the Issues screen can be filtered with `label:build-failed`.

**Structured metadata at the top of the body**: the package name and version are embedded in the body in structured form, not as free text in the title. In addition to a human-readable Markdown table, a JSON blob is also included as an HTML comment to make parsing more reliable (a Markdown table can be mis-parsed if formatting breaks or if a log line happens to contain `|`, so the HTML comment is treated as the source of truth for machine parsing).

```markdown
<!-- dorgann-meta: {"package":"foo","version":"1.2.3"} -->

| Field   | Value |
|---------|-------|
| Package | foo   |
| Version | 1.2.3 |
```

The check-updates step extracts `package`/`version` from the `dorgann-meta` HTML comment of any open `build-failed` Issue via a regex, and compares it against the latest version (see 4.2). If the design only checked "does an Issue exist" without recording the version, then once upstream published a new version the build would be skipped forever, so it's essential to compare the recorded version against the latest one.

**Link to the Actions run**: rather than copying a log excerpt into the Issue body, the body just links to the run. Reasoning, settled after actually using this on a couple of real failures: a fixed `tail -n 200` is a poor fit either way — long enough to bloat the Issue in the common case, yet not guaranteed to actually contain the relevant error for a build that fails many steps and hundreds of lines into a verbose one (e.g. a `meson`/`cmake` configure log). The run itself keeps the complete, unclipped log for the repository's full retention period (90 days by default — the same window build artifacts live for, per 4.4), which is long enough to investigate and fix a failure in practice; an excerpt would only ever be a lossy, harder-to-search copy of what's already sitting one click away.

### 4.6 Branch-rebuild mode: manual fixes beyond a version bump

The whole system as designed above only automates a *mechanical* version bump — renaming the `.cygport` file and substituting the bare old-version string. In practice, a real upstream release can require more than that to actually build: a missing `BUILD_REQUIRES` (a language runtime the build needs but doesn't declare — seen in practice for Fortran, a `gobject-introspection` dependency, and a Lua interpreter, none of which cygport or `cygport_depends.sh` can infer on their own, matching how `cygwin/scallywag` itself handles this — see `scripts/cygport_depends.sh`'s own header), or an ABI change that renames a `PKG_NAMES` entry (e.g. `libfoo0` → `libfoo1`). Neither is something dorgann can decide on its own; both need a human editing the recipe's actual content, not just its version string.

The gap this closes: on a build failure, dorgann had nothing to hand a human to fix *from* — the renamed `.cygport` only ever existed inside the failed job's own ephemeral checkout, so fixing it meant redoing the rename by hand from scratch. And even after a fix, there was no way to re-run the fixed recipe through dorgann's own build/validate pipeline (cygport + xezat, which only run on dorgann's windows-latest CI) without yacp itself gaining that whole environment — an "embed dorgann's CI into yacp" undertaking deliberately being avoided here.

The fix keeps all of that CI on dorgann's side, and only asks yacp to accept ordinary branch pushes (which a human already does by hand for every dorgann-related change, per this project's own working convention):

- **On failure, dorgann now also pushes a *draft* PR** to the same deterministic branch a successful run would use (`dorgann/<pkg>-<ver>`), containing whatever `Bump version` (or `Detect existing cygport`, see below) already produced — typically just the renamed, version-substituted `.cygport`, since the build itself didn't get far enough to touch the README/changelog. This is the concrete starting point a human pulls, edits by hand (`BUILD_REQUIRES`, `PKG_NAMES`, ...), and pushes straight back to that same branch.
- **`build-package.yml` gained a `branch` input.** When given, `Checkout yacp` still checks out yacp-dev/ports's own default branch as usual (see below for why), and a new `Overlay branch content` step (`scripts/overlay_branch_package.sh`) replaces just the package directory's content with that branch's version — removing it first (`git rm -r`) before checking the branch's copy back in, since `git checkout <treeish> -- <path>` only adds/updates files, never deletes ones the working tree already has but the source treeish doesn't (which matters here, since a version bump deletes the old-version `.cygport`/`.src.patch`). This shows up as a plain uncommitted diff against master, so `Bump version` is swapped for `Detect existing cygport` (`scripts/detect_cygport_file.sh`, read-only: finds the sole `.cygport` now in the directory and parses its version) exactly as before — the branch's `.cygport` is already at its target name, so there's nothing left to rename. Every later step reads through whichever of the two ran (their outputs are concatenated in each expression, e.g. `${{ steps.bump.outputs.cygport_file }}${{ steps.detect.outputs.cygport_file }}` — exactly one is ever non-empty), so the rest of the pipeline doesn't need to know which path produced it.
- A human re-triggers the rebuild manually: `gh workflow run build-package.yml -f package=<pkg> -f branch=dorgann/<pkg>-<ver>`. If it now passes, the normal `Create Pull Request` step (not the draft one) updates the same branch/PR, and a following `gh pr ready` step explicitly marks it ready for review. Leaving `draft` unset on `Create Pull Request` (defaulting to `false`) does **not** un-draft an already-draft PR on its own, despite what the action's own docs implied — confirmed by a real branch-rebuild success where the title/body updated correctly but `isDraft` stayed `true` until `gh pr ready` was added.
- `branch` doesn't actually have to be typed out by hand: a **Detect existing branch** step runs whenever `branch` is left empty but `version` is given, and checks whether `dorgann/<package>-<version>` already exists in yacp (a plain `gh api repos/{owner}/{repo}/branches/{branch}` call, no local checkout needed for this check). If it does, this run automatically behaves as a branch-rebuild rather than attempting a fresh bump that would just fail on `bump_version.sh`'s own "already at this version" refusal -- so re-running with the exact same `-f package=<pkg> -f version=<ver>` invocation is enough once a branch/draft PR/Issue already exists for that version, without needing to separately compute and pass `branch=dorgann/<pkg>-<ver>`.

**Why `Checkout yacp` doesn't just check out `branch` directly** (the first design tried, and reverted after a real failure): `peter-evans/create-pull-request` determines its "working base" from whatever ref was actually checked out, and reconciles that against the `branch:`/`base:` inputs it's given by rebasing — replaying only the commits made *during that run* on top of `base`. A branch-rebuild run that ends up making no new commits (e.g. it fails again, the same way the original build did) has nothing to replay, so that reconciliation collapsed the entire target branch down to be byte-identical to `master` and then deleted it outright, treating it as a PR whose change was no longer needed (`Branch '...' no longer differs from base branch 'master'` / `Deleting branch '...'`, confirmed by a real run against libucl, which silently destroyed the human's already-pushed fix along with the branch). Overlaying just the one directory's content on top of a normal `master` checkout avoids this class of problem entirely, since the human's fix is now an ordinary uncommitted diff — precisely the shape this action already handles correctly.

Deliberately deferred for now (the second half of the two options this design was chosen from): automatically detecting a yacp-side push to one of these branches and re-triggering the rebuild via `repository_dispatch` (the same cross-repo mechanism `distribute.yml`/`publish.yml` already use for merge-triggered publishing, 4.4.2) — manual `workflow_dispatch` is enough to validate the mechanism first.

## 5. Implementation Policy (separating workflow YAML from scripts)

- Workflow YAML files should only contain "task invocation" — actual logic (Repology queries, build logic, etc.) is factored out into scripts.
  - Embedding logic in YAML doesn't get syntax highlighting or static analysis, and every edit requires an Actions run to verify.
  - Scripts can be debugged locally and reused as-is when triggered manually via `workflow_dispatch`.
- Ruby is the recommended language. Since xezat (written in Ruby) already has version-comparison and bump logic, the Repology-side "is this a new version" judgment can piggyback on it too (either directly, or added as an xezat subcommand), reusing existing know-how such as handling cygport's version notation.
- Values are passed from scripts to GitHub Actions uniformly via `$GITHUB_OUTPUT`.
- Boilerplate GitHub API work — creating PRs, searching/closing Issues, etc. — should prefer a proven Marketplace Action over a custom implementation.
- Scripts take their input via CLI args/environment variables and are not directly dependent on the GitHub Actions context, so they remain reproducible when run locally.

## 6. GitHub Actions cost/limits assumptions

**Since this runs in a public repository, standard-runner (including Windows) Actions minutes and artifact storage are free and unlimited.** An earlier assumption of budget constraints (e.g. "effectively 1,000 Windows minutes/month") was based on treating this as a private repo — that doesn't apply to a public repo, so it's been corrected here.

> GitHub Actions usage is free for self-hosted runners and for public repositories that use standard GitHub-hosted runners.
> — [GitHub Actions billing](https://docs.github.com/billing/managing-billing-for-github-actions/about-billing-for-github-actions)

Likewise, the Free plan's 500MB artifact-storage quota etc. applies to private repos — public repo build artifacts are exempt from that quota ([community discussion example](https://github.com/orgs/community/discussions/26438)). The only case where paying is worth considering is using GitHub-hosted "Larger runners" (which are always billed regardless of public/private).

| Item | Detail | Source |
|---|---|---|
| Standard-runner Actions minutes (public repo) | Free, unlimited | [GitHub Actions billing](https://docs.github.com/billing/managing-billing-for-github-actions/about-billing-for-github-actions) |
| Artifact storage (public repo) | Free, unlimited (the ~500MB private-repo quota doesn't apply) | Same as above, [community discussion #26438](https://github.com/orgs/community/discussions/26438) |
| Larger runners | Always billed, public or private | Same as above |
| Concurrent jobs (Free plan) | 20 across the whole account/org (shared with other repos' CI) | [Actions limits](https://docs.github.com/en/actions/reference/limits) |
| Actions artifact/log retention | Default 90 days. Private repos can set 1–400 days; public repos max out at 90 | [Configuring the retention period](https://docs.github.com/en/organizations/managing-organization-settings/configuring-the-retention-period-for-github-actions-artifacts-and-logs-in-your-organization) |
| GitHub Pages site size | Published site capped at 1GB (source repo recommended to stay under 1GB too) | [GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits) |
| GitHub Pages bandwidth | Soft limit of 100GB/month | Same as above |
| Max runtime for a single job | 6 hours | [Actions limits](https://docs.github.com/en/actions/reference/limits) |
| `GITHUB_TOKEN` REST API rate limit | 1,000 req/hour per repository (60 req/hour unauthenticated) | [Rate limits for the REST API](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api#primary-rate-limit-for-github_token-in-github-actions) |

Now that minutes/storage are effectively unlimited, there's no need to derive an upper bound on the number of monitored packages by budgeting Windows minutes. The two things that still need consideration are the concurrent-job cap (20 across the account) and GitHub Pages' site size/bandwidth (for devel package distribution).

## 7. Implementation Roadmap

Rather than implementing everything at once, validate incrementally, starting from the highest-risk part (whether a cygport build on Windows actually works in Actions).

**Step 1: `workflow_dispatch` for a single package (done)**

Build a workflow that takes `package` and `version` as `workflow_dispatch` inputs, does a cygport bump and build via xezat on `windows-latest`, and just uploads the dist as an artifact. Including the version as an input lets us defer the entire Repology/GitHub Releases API version-judgment logic (4.2.1). PR creation against yacp (4.4.1) is also excluded at this stage — the focus is purely on validating "does the Windows build environment work in Actions."

Implemented as `.github/workflows/build-package.yml` / `scripts/*.sh`; the full pipeline is documented in 4.3. Beyond the base cygport-build-on-Windows question, this also validated using xezat for the full prep/validate/bump/port cycle (originally deferred in the design phase as an unverified Windows-Ruby risk, since it pulls in native-extension gems via github-linguist) — it works, given a genuine Cygwin ruby/gem rather than the runner's preinstalled native Windows Ruby. `Show diff` (git-staged, package directory only) confirmed the right files changed with the right content before Step 2 added actual persistence.

**Step 2: Add PR creation against yacp (done)**

Add branch push and PR creation to yacp (4.4, 4.4.1) to the Step 1 workflow. This is where the fine-grained PAT / GitHub App token setup and permissions get validated. `package`/`version` remain manual inputs.

Implemented via `peter-evans/create-pull-request` in the same workflow, checking out yacp with a fine-grained PAT (originally `YACP_SECRET`, scoped to yacp-dev/ports with `contents:write`/`pull-requests:write`; since replaced by a GitHub App installation token, per 4.4.1) instead of the default `GITHUB_TOKEN`. Branch/commit-message/title are deterministic from `package`+`version` (`dorgann/<PN>-<PV>` / `<PN>-<PV>`, the latter matching yacp's own existing commit convention), so re-running for the same package/version updates the existing PR rather than piling up duplicates. Staging is restricted to the same pathspec `Show diff` already uses (`add-paths`, since it defaults to a plain `git add -A` over the whole checkout otherwise), and the cygport build tree is deleted first via cygport's own `clean` step -- otherwise the action's own internal `git stash --include-untracked` (used to restore the working tree after committing) walks into it and hits a symlink Windows Git can't index, aborting the whole step. Verified end-to-end against a real (kept-open) PR, [yacp-dev/ports#48](https://github.com/yacp-dev/ports/pull/48), containing exactly the three expected changed files (README, `.cygport`, `.src.patch`) and nothing else.

**Step 3: Automate version determination**

Replace the manual `version` input with automatic determination via Repology / the GitHub Releases API (4.2.1). The input becomes just `package`.

**Step 4: Daily cron and matrix expansion**

Reusing the "process one package" logic built through Step 3, add a check-updates job (4.2) that scans all of `packages.yml`, and a build job that expands only the updated packages into a matrix (4.3), triggered automatically via `schedule: cron`.

**Step 5: File an Issue on failure (done)**

Add Issue filing on build failure (label, metadata, run link — 4.5), and skip logic for the next loop (4.2).

Implemented as two new steps in `.github/workflows/build-package.yml` / `scripts/{report_build_failure,close_failure_issue,find_failure_issue}.sh`, out of numeric order like Step 6 — it has no dependency on Steps 3/4's daily-cron loop, only on there being a build job at all. **File failure Issue** is the job's last step, with its own `if: failure()` (so it runs regardless of which earlier step failed — bump, cygport build, xezat, Create Pull Request, ...); **Close failure Issue** has no `if:` of its own and so only runs on the success path, per GitHub Actions' implicit `if: success()` for steps that don't declare one.

One design point not fully spelled out in 4.5 itself, resolved here: **avoiding duplicate Issues across repeat failures**. `find_failure_issue.sh` searches open `build-failed` Issues for one whose `dorgann-meta` comment already names the same package (a literal JSON substring match via `jq --arg`, not a title search — the title also carries the version and changes on every failure). `report_build_failure.sh` reuses this to edit the existing Issue in place (fresh version) rather than piling up a new one on every retry; `close_failure_issue.sh` reuses it the same way to find what to close.

The original design also called for a log excerpt in the Issue body; dropped after actually using this against a couple of real failures, in favor of just the run link — see 4.5 for the reasoning.

The `skip logic for the next loop (4.2)` — comparing an open Issue's recorded version against the latest before deciding whether to retry — has nothing to run it yet (that's check-updates, part of Step 3/4's daily-cron loop, not implemented), but the Issue side is already in the exact shape 4.2 expects to read back (`dorgann-meta`'s `version` field).

**Step 6: Publish devel packages to gh-pages (done)**

Add the 4.4.2 `workflow_dispatch` workflow (takes an `artifact_id` and updates gh-pages). This is independent of Steps 1–5, so it can be slotted in at any point in the implementation order — implemented here right after Step 2, out of numeric order, since it doesn't depend on Steps 3-5 at all.

Implemented as `.github/workflows/publish.yml` / `scripts/{download_dist_artifact,checkout_gh_pages,layout_release_area,generate_setup_ini,publish_gh_pages,ensure_pages_enabled}.sh`. Runs on `ubuntu-latest`, not `windows-latest` — none of this needs Cygwin, since `calm`/`mksetupini` is plain Python (confirmed against calm's own `setup.cfg`: a real installable package with a `mksetupini` console_scripts entry point, `pip install git+https://github.com/cygwin/calm.git` puts it straight on `PATH`) and the gh-pages update is plain git.

Two gaps from the original 3.2 design turned up only once actually run against a real build:

- cygport's own `dist/` layout (`dist/<PN>/[<subpkg>/]<file>.{hint,tar.xz}`, confirmed against cygport's `pkg_pkg.cygpart` and a real build's artifact) isn't the `<rel_area>/x86_64/release/...` layout `mksetupini` expects. Reshaping this is normally calm's own upload-processing job on the real Cygwin infrastructure, which isn't in use here, so `layout_release_area.sh` does it directly.
- `mksetupini --disable-check` needs `missing-build-depended-package` in addition to the two named in the original 3.2 text (`missing-required-package`, `missing-depended-package`) — cygport's generated `*-src.hint` always records `build-depends: cygport` plus whatever the package itself needs (e.g. `zlib-devel`), and neither of the other two checks cover that; without it `mksetupini` refused to write `setup.ini` at all.

`gh-pages` didn't exist yet as of implementing this, so `checkout_gh_pages.sh` bootstraps it as a fresh orphan branch on first run rather than requiring it to be created manually first. Enabling GitHub Pages itself, however, could *not* be automated: `GITHUB_TOKEN`'s `pages: write` permission is scoped to the newer artifact-deploy flow (`actions/deploy-pages`) and returns `403 Resource not accessible by integration` against the classic branch-source config endpoint (`POST /repos/{owner}/{repo}/pages`) — confirmed by an actual run. `ensure_pages_enabled.sh`'s attempt is kept as a `continue-on-error` best effort in case that ever changes, but enabling Pages (Settings → Pages → Deploy from a branch → `gh-pages` / `/`) is, in practice, still a one-time manual step.

Verified end-to-end: published `yacp-dev/ports`'s `last` package (from the same artifact used to verify Step 2) to gh-pages, and confirmed the live site actually serves it (`.../x86_64/setup.ini`, HTTP 200, with correct `install:`/`source:`/`depends2:` entries for `last`/`last-debuginfo`/`last-src`).

**Release-area layout, corrected after real multi-subpackage use** (`layout_release_area.sh`): the first version flattened every `.hint`-containing directory straight into `x86_64/release/<that directory's own basename>/`, which happened to look right for single-package builds like `last`, but for a package with real `PKG_NAMES` splits (`libucl`, producing `libucl`/`libucl5`/`libucl-devel`/`libucl-debuginfo`/`lua-libucl`) it put every one of those as a *sibling* of `libucl` at the top level, instead of nested under it — confirmed by inspecting the actual published gh-pages tree. The real Cygwin mirrors' own convention (and calm's `package.py:collect_files_package_dir`, which only requires each binary package's own files to share one directory — it doesn't care how many parent levels sit above that) is a further level down: `x86_64/release/<source package>/<binary package>/...`. Fixed to locate cygport's `dist/` directory by name (not by a fixed depth, since how many wrapper levels precede it depends on what the Upload dist artifact step globbed) and lay each of its top-level `<PN>/` entries out as a source-package directory, with the main package (+ the `-src` pseudo-package cygport always drops alongside it, using an empty distsubdir the same way) nested in a `<PN>/<PN>/` binary-package directory of its own, and every other `dist/<PN>/<subpkg>/` preserved as `<PN>/<subpkg>/`. Fixing this on already-published packages needed a one-off manual cleanup too: the old flat sibling directories (e.g. `libucl-devel`) don't correspond to anything in a fresh `dist/<PN>/` scan, so `layout_release_area.sh` has no way to know to remove them on its own -- they were deleted by hand directly on `gh-pages`.

**Concurrency**, added after a real race: every run of `publish.yml` reads, reshapes, and force-pushes the *entire* `gh-pages` branch as one tree (3.3), regardless of which package/artifact it's publishing -- so two runs overlapping at all is unsafe even for different packages, not just the same one. Confirmed by triggering `last` and `libucl` publishes a few seconds apart: the later run's `Checkout gh-pages` cloned before the earlier run's `Commit and force-push gh-pages` had landed, so its own force-push silently reverted the earlier run's changes (the earlier package's release-area fix disappeared from the published tree with no error anywhere). Fixed with a workflow-level `concurrency` block using one fixed group name for the whole workflow (not parameterized by `artifact_id`/package, since the unsafety isn't package-specific) and `cancel-in-progress: false` -- the fix here is queueing ("wait your turn"), not cancellation, since cancelling an in-progress publish would risk the same kind of lost-update problem this is meant to prevent.

**Step 7: Branch-rebuild mode for manual fixes (4.6) (done)**

Added once real Step 1/2 runs against actual upstream releases (`libmbd`, `libmodulemd`, `libucl`) kept hitting build failures a pure version bump can't fix on its own (missing `BUILD_REQUIRES`, ABI-driven `PKG_NAMES` renames) — see 4.6 for the full design and reasoning. Implemented in `build-package.yml` (`branch` input, `Detect existing cygport` step, `Overlay branch content` step, `Create draft Pull Request (on failure)` step, `Mark Pull Request ready for review` step) and `scripts/{detect_cygport_file,overlay_branch_package}.sh`.

The design went through two real revisions before landing, both driven by actual failed runs rather than caught in review — see 4.6 for the full detail on each:

- Checking out `branch` directly (via `actions/checkout`'s `ref:`) broke `peter-evans/create-pull-request`'s base-branch reconciliation and silently deleted the target branch (and the human's already-pushed fix along with it) the first time a rebuild made no new commits. Replaced with overlaying just the package directory's content onto an ordinary `master` checkout instead.
- That overlay then hit a second real issue: a human's locally-committed fix carried CRLF line endings into the blob itself, which cygport can't source as a bash script. `overlay_branch_package.sh` now strips `\r` defensively after checking the branch's content in.
- Leaving `draft` unset on `Create Pull Request` (defaulting to `false`) turned out not to un-draft an already-draft PR on update, contrary to what the action's own docs implied — a separate `gh pr ready` step now handles it explicitly.

Verified end-to-end against a real human-fix-and-rebuild cycle: `libucl` 0.9.4 failed to build (missing `BUILD_REQUIRES` for a Lua interpreter and `gobject-introspection`/Fortran on other packages along the way), dorgann filed [yacp-dev/dist#1](https://github.com/yacp-dev/dist/issues/1) and pushed a draft PR to a `dorgann/libucl-0.9.4` branch; after the missing `BUILD_REQUIRES` were added directly on that branch (by hand) and the build re-run with `-f branch=dorgann/libucl-0.9.4`, the build passed, [yacp-dev/ports#50](https://github.com/yacp-dev/ports/pull/50) was updated and marked ready for review (`isDraft: false`), and the Issue was closed automatically.
