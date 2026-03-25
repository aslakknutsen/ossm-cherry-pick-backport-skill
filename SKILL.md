---
name: cherry-pick-backport
description: Backport upstream commits into downstream release branches via cherry-pick. Use when the user mentions backport, cherry-pick, or porting upstream commits to an older branch.
---

# Cherry-Pick Backport

Backport one or more upstream commits into one or more downstream release branches.

The user provides:
- **Source SHA(s)** — commits to backport, probably from upstream (comma or space separated)
- **Target branch(es)** — downstream release branches to cherry-pick into (comma or space separated)
- **Push remote** (optional) — remote name to push cherry-pick branches to
- **Extra context** (optional) — known issues, files to skip, etc.

## Phase 0: Parse, Detect Remotes, Plan

1. Parse SHAs and branches from the user's message. Accept comma-separated, space-separated, or one-per-line.

2. **Combined mode** (multiple SHAs → **one** downstream branch, **one** worktree, **N** preserved cherry-pick commits). Enable **only** when the user is explicit — never infer combined mode from a bare list of SHAs and branches.
   - **Keywords** (case-insensitive): `together`, `as one branch`, `combined`, `single branch` — with **one** target branch and **two or more** SHAs, e.g. `Backport abc def together into release-2.4`.
   - **Bracket grouping**: `[abc123 def456]` or `[abc123, def456]` into a **single** branch, e.g. `[abc def] into release-2.4`.

3. **Planning — build jobs** (a **job** is either `(single SHA, branch)` or `(ordered SHA list, branch)`):
   - If **combined mode**: one job per explicit combined request: `(SHA1, SHA2, …, branch)`. Do **not** expand into a cross-product of single SHAs for that branch.
   - Otherwise (default): **cross-product** of every parsed SHA with every parsed branch — each job is `(one SHA, one branch)`.

4. **Ordering SHAs within a combined job** (must run before Phase 1):
   - Resolve each SHA with `git rev-parse`.
   - Verify the SHAs lie on a **single ancestral line** suitable for cherry-pick (each consecutive pair in chronological order must be ancestor/descendant). If not (e.g. merge commits or unrelated tips), **stop and ask** the user for an order or to split the work.
   - Compute **oldest → newest** order, e.g. find `BASE=$(git merge-base "$@")` and the **tip** among the set (the commit in the set that is a descendant of every other in the set, when such a unique tip exists), then `git rev-list --reverse "$BASE"..<tip>` and **filter** to the SHAs in the job, preserving that order. If tip/base logic is ambiguous, **stop and ask**.

5. Detect git remotes by running `git remote -v`:
   - **Upstream remote**: the remote whose URL contains `istio/istio` (the upstream org/repo). Store the remote name.
   - **Downstream remote**: the remote whose URL contains `openshift-service-mesh/istio`. Store the remote name.
   - If either cannot be determined, ask the user.

6. For each source SHA in the plan (flatten jobs), check if it exists locally (`git cat-file -t <sha>`). If not, fetch it from the upstream remote: `git fetch <upstream-remote> <sha>`.

7. Push remote is **never assumed**. Only push if the user explicitly provides a remote name.

## Phase 1: Create Worktrees

### Label, path, and branch name

For **single-SHA** jobs (`SHA`, `BRANCH`):

- `SHORT="${SHA:0:8}"`
- `WORKTREE="/tmp/cherry-pick-${SHORT}-into-${BRANCH}"`
- Cherry-pick branch name: `cherry-pick-${SHORT}-into-${BRANCH}`

For **combined** jobs (ordered SHAs `S1..Sn`, `BRANCH`):

- `SHORTi="${Si:0:8}"` for each.
- Build `LABEL` from `SHORT1-SHORT2-...-SHORTn` joined with `-`.
- If `LABEL` exceeds **60 characters** or contains unsafe path characters, set `LABEL="h$(printf '%s' "$*" | sha256sum | awk '{print substr($1,1,8)}')"` (prefix `h` + 8 hex chars from the UTF-8 concatenation of full SHAs).
- `WORKTREE="/tmp/cherry-pick-${LABEL}-into-${BRANCH}"`
- Cherry-pick branch name: `cherry-pick-${LABEL}-into-${BRANCH}`
- Hints file: `/tmp/backport-hints-${LABEL}-${BRANCH}`

For each job:

```bash
git worktree add "$WORKTREE" "<downstream-remote>/${BRANCH}"
```

If the worktree path already exists, remove it first: `git worktree remove "$WORKTREE" --force`.

## Phase 2: Dispatch Sub-Agents

Launch one `Task` sub-agent per **job**. Max 4 concurrent — batch the rest.

Use `subagent_type: "generalPurpose"` for each sub-agent.

The prompt for each sub-agent must be **fully self-contained** (it has no access to this conversation). Use the **single-SHA** template or the **multi-SHA combined** template below.

---

BEGIN SUB-AGENT PROMPT TEMPLATE (single SHA):

You are a release engineer backporting upstream commit `{SHA}` into the `{BRANCH}` branch.

Your working directory is `{WORKTREE}`. Use `working_directory: "{WORKTREE}"` for ALL shell commands.

### Setup

1. Create the cherry-pick branch:
   ```
   git checkout -b cherry-pick-{SHORT}-into-{BRANCH}
   ```
2. Run the backport hints script:
   ```
   bash {SKILL_DIR}/scripts/generate-backport-hints.sh {SHA} {BRANCH}
   ```
3. Read the hints file at `/tmp/backport-hints-{SHORT}-{BRANCH}`. These describe known divergences between this branch and the upstream source. Use them throughout — do not waste time rediscovering them.
4. Attempt the cherry-pick:
   ```
   git cherry-pick {SHA} || true
   ```

### Conflict Resolution

If the cherry-pick produced conflicts:
1. Find all files with conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`).
2. Resolve each conflict, preserving the upstream commit's intent within the older branch's architecture.
3. Remove all conflict markers.
4. `git add` the resolved files and run `git cherry-pick --continue`.

### Downstream-Only Files

If `istio.deps` was modified by the cherry-pick, restore the **pre-pick** (target branch) version after the pick completes, then fold that into the cherry-pick commit:
```
git checkout HEAD^ -- istio.deps
git add istio.deps
git commit --amend --no-edit
```
(`HEAD^` is the target branch tip before this cherry-pick; upstream content must not remain.)

This file is maintained separately downstream and must never be overwritten by upstream commits.

### Code Adaptation

Even if the cherry-pick was clean, audit the changed files for branch-specific mismatches. Use the hints file. Adapt as needed:
- **Import paths / APIs**: internal APIs or file structures may differ on this branch. Update imports and function calls to match.
- **Language features**: do not use Go features or stdlib additions unsupported by this branch's Go version (check the hints for the Go version).
- **Dependencies**: if the upstream commit uses newer third-party packages, adapt the code to work with the versions in this branch's go.mod. Do not bump dependency versions unless the fix cannot work otherwise.
- **Test fixtures / golden files**: update hardcoded version strings or expected outputs that reference the upstream branch.

### Verification

1. Identify which test suites cover the modified code.
2. Run them: `go test ./path/to/package/...`
3. If tests fail, analyze the failure, fix the code, and re-run.
4. If the backport requires a massive architectural rewrite that makes it fundamentally incompatible, stop and explain why.

### Finalization

If you made ANY changes beyond a clean cherry-pick (conflict resolution, API adaptation, syntax downgrades, test fixes):
1. Amend the commit: `git commit --amend` (do NOT use `--no-edit`).
2. Keep the original commit message, author intent, and the `(cherry picked from commit ...)` line.
3. Append git trailers at the very end of the message:
   ```
   Backport-Change: <one-line summary of what you modified or dropped>
   Backport-Reason: <one-line explanation of why the adaptation was needed>
   ```

### Return

When done, output a single summary line in this format:
```
RESULT: {SHA} into {BRANCH} — <status: clean|adapted|failed> — <one-line detail>
```

END SUB-AGENT PROMPT TEMPLATE (single SHA)

---

BEGIN SUB-AGENT PROMPT TEMPLATE (multi-SHA combined):

You are a release engineer backporting **multiple** upstream commits into the `{BRANCH}` branch on **one** branch, preserving **one git commit per upstream SHA**.

Ordered SHAs (oldest first): `{SHA1} {SHA2} …`  
`LABEL` = `{LABEL}` (used in paths and branch name).

Your working directory is `{WORKTREE}`. Use `working_directory: "{WORKTREE}"` for ALL shell commands.

### Setup

1. Create the cherry-pick branch:
   ```
   git checkout -b cherry-pick-{LABEL}-into-{BRANCH}
   ```
2. Run the combined backport hints script:
   ```
   bash {SKILL_DIR}/scripts/generate-backport-hints.sh --combined {LABEL} {BRANCH} {SHA1} {SHA2} ...
   ```
3. Read the hints file at `/tmp/backport-hints-{LABEL}-{BRANCH}`. Use every `=== upstream … ===` section. Do not waste time rediscovering divergences.
4. Cherry-pick the **entire series in one command** (order must match oldest → newest):
   ```
   git cherry-pick {SHA1} {SHA2} ... || true
   ```

### Conflict Resolution

If the cherry-pick stops with conflicts:
1. Resolve conflicts for the **current** commit in the series (same rules as single-SHA).
2. `git add` resolved files and `git cherry-pick --continue`.
3. Repeat until the series completes or the operation fails irrecoverably.

### Downstream-Only Files

After **each** commit in the series lands (including after `git cherry-pick --continue`), if that commit modified `istio.deps`:
```
git checkout HEAD^ -- istio.deps
git add istio.deps
git commit --amend --no-edit
```
(`HEAD^` is the parent of the current cherry-pick commit — the downstream state before that pick. Upstream `istio.deps` content must not remain.)

### Code Adaptation

After each pick or after the full series (as appropriate), audit changed files using the hints for the relevant upstream SHA section. Same adaptation rules as single-SHA (imports, Go version, deps, gateway-api, test fixtures).

### Verification

Run targeted tests covering all modified areas (possibly after the full series). Fix failures; if a fix belongs to a specific commit in the series, use `git rebase -i` to **edit** that commit and fold fixes, or split as needed so each cherry-picked commit remains coherent.

### Finalization (series)

- Commits that are **clean** cherry-picks need **no** message change.
- For **any** commit in the series where you changed the tree beyond a pure pick (conflicts, adaptation, test fixes, `istio.deps` amend): **reword** that commit only — keep the original message body and `(cherry picked from commit <that-sha>)`, and append:
  ```
  Backport-Change: <one-line summary>
  Backport-Reason: <one-line explanation>
  ```
  Use `git rebase -i` with `reword` / `edit` on those commits (do not strip cherry-pick lines).

### Return

When done, output:
```
RESULT: {SHORT1}+{SHORT2}+… into {BRANCH} — <status: clean|adapted|failed> — <one-line detail>
```
(use 8-char prefixes of each SHA, joined with `+`)

END SUB-AGENT PROMPT TEMPLATE (multi-SHA combined)

---

To resolve `{SKILL_DIR}`, use the absolute path to this skill's directory. You can determine it from the path of this SKILL.md file — it is the parent directory. For example, if this file is at `/home/user/repo/.cursor/skills/cherry-pick-backport/SKILL.md`, then `{SKILL_DIR}` is `/home/user/repo/.cursor/skills/cherry-pick-backport`.

## Phase 2.5: Review Sub-Agents

After ALL backport sub-agents from Phase 2 have completed, launch a second round of review sub-agents — one per **job** whose backport status was `clean` or `adapted` (skip `failed`).

- Use `subagent_type: "generalPurpose"`, `readonly: true`.
- Max 4 concurrent, batch the rest.
- Each review agent is a **fresh agent** with no shared context from the backport agent.

The review agent does **not** fail or block the backport. It surfaces concerns for the user to evaluate.

Use the **single-SHA** or **multi-SHA** review template as appropriate.

---

BEGIN REVIEW SUB-AGENT PROMPT TEMPLATE (single SHA):

You are a code reviewer verifying a cherry-pick backport. Your job is to compare the backported result against the original upstream commit and flag any unjustified divergences.

Your working directory is `{WORKTREE}`. Use `working_directory: "{WORKTREE}"` for ALL shell commands. Do NOT modify any files.

### Inputs

- Original upstream commit: `{SHA}`
- Target branch: `{BRANCH}`
- Cherry-pick branch (currently checked out): `cherry-pick-{SHORT}-into-{BRANCH}`
- Hints file: `/tmp/backport-hints-{SHORT}-{BRANCH}`

### Steps

1. Read the original commit message to understand intent:
   ```
   git log -1 --format=%B {SHA}
   ```

2. Read the hints file at `/tmp/backport-hints-{SHORT}-{BRANCH}`. These describe known, expected divergences (Go version differences, dependency deltas, gateway-api migration, downstream-only files). Divergences explained by these hints are acceptable.

3. Show the original upstream diff (what the commit changed in its original context):
   ```
   git diff {SHA}~1..{SHA}
   ```

4. Show the backported diff (what the cherry-pick branch changed relative to its base):
   ```
   git log -1 -p HEAD
   ```

5. Compare the two diffs. For every difference between them, determine whether it is:
   - **Expected**: explained by the hints file or obvious branch context (different import paths, older APIs, file renames).
   - **Suspicious**: not explained by hints or context. This includes:
     - Dropped hunks (code from the original that is missing in the backport without explanation)
     - Unrelated new code not present in the original commit
     - Logic inversions or semantic changes to conditionals, return values, error handling
     - Removed or weakened test coverage
     - Changes to files not touched by the original commit

### Output

Return a single structured result:
```
REVIEW: {SHA} into {BRANCH} — <pass|concerns> — <detail>
```

- Use `pass` if all divergences are justified.
- Use `concerns` if any suspicious divergences exist. List each concern as a bullet point in the detail.

END REVIEW SUB-AGENT PROMPT TEMPLATE (single SHA)

---

BEGIN REVIEW SUB-AGENT PROMPT TEMPLATE (multi-SHA combined):

You are a code reviewer verifying a **multi-commit** cherry-pick backport. Compare the **combined** upstream effect against the **series** of backported commits.

Your working directory is `{WORKTREE}`. Use `working_directory: "{WORKTREE}"` for ALL shell commands. Do NOT modify any files.

### Inputs

- Upstream SHAs (oldest → newest): `{SHA1} {SHA2} …`
- Target branch: `{BRANCH}`
- Cherry-pick branch: `cherry-pick-{LABEL}-into-{BRANCH}`
- Hints file: `/tmp/backport-hints-{LABEL}-{BRANCH}`
- Let `OLDEST` = `{SHA1}` and `NEWEST` = last SHA in the ordered list (after verifying they are on one ancestral line).

### Steps

1. For each upstream SHA, read intent: `git log -1 --format=%B <sha>`.

2. Read `/tmp/backport-hints-{LABEL}-{BRANCH}`. Divergences explained there (per `=== upstream … ===` section) are acceptable.

3. **Upstream aggregate diff** (linear series): use the range from the parent of the oldest commit through the newest:
   ```
   git diff OLDEST^..NEWEST
   ```
   (If `OLDEST^` is ambiguous in your repo, use `git merge-base OLDEST^ NEWEST` and document in the review.)

4. **Backported aggregate diff** relative to the downstream base before the cherry-picks (the commit that was `HEAD` when the worktree was created — typically the tip of `{BRANCH}`):
   ```
   git log --oneline -n <N> HEAD
   git diff <base-before-picks>..HEAD
   ```
   where `<N>` is the number of cherry-picked commits. To find the base: `git merge-base HEAD cherry-pick-{LABEL}-into-{BRANCH}` may not apply; instead use `git log --first-parent` or the parent of the first cherry-pick: `git rev-parse HEAD~<N>` if exactly `N` commits were added.

5. Compare upstream series vs backport series: same suspicious patterns as single-SHA (dropped hunks, unrelated code, logic changes, tests). Check **each** commit message still contains the correct `(cherry picked from commit …)` line for its SHA.

### Output

```
REVIEW: {LABEL} into {BRANCH} — <pass|concerns> — <detail>
```

END REVIEW SUB-AGENT PROMPT TEMPLATE (multi-SHA combined)

---

## Phase 3: Collect Results

After all backport and review sub-agents complete:

1. Report a summary table with columns: **job** (e.g. `abc12345 → release-2.4` or `abc12345+def67890 → release-2.4`), **backport status**, **review verdict**, **details**.

2. If the user specified a push remote, for each job where review is `pass` (or the user explicitly overrides):
   ```bash
   git push -u <push-remote> cherry-pick-<SHORT-or-LABEL>-into-<BRANCH>
   ```
   Then optionally create PRs (list **all** SHAs in the title or body for combined jobs):
   ```bash
   gh pr create \
     --base "<BRANCH>" \
     --head "cherry-pick-<SHORT-or-LABEL>-into-<BRANCH>" \
     --title "[cherry-pick] <SHORT-or-LABEL> into <BRANCH>" \
     --body "Cherry-pick of <SHA or SHA list> into <BRANCH>."
   ```
   Do **not** push jobs where review raised concerns unless the user says to proceed.

3. Clean up all worktrees:
   ```bash
   git worktree remove /tmp/cherry-pick-<SHORT-or-LABEL>-into-<BRANCH>
   ```
