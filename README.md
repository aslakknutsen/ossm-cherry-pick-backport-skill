# OSSM Cherry-Pick Backport Skill

An AI coding agent skill that backports commits into downstream release branches
using cherry-pick, with AI-assisted conflict resolution, code adaptation, and
automated review. Works with Cursor and Claude Code.

## What it does

Given one or more commit SHAs and one or more target branches, the skill:

1. Detects your git remotes (upstream `istio/istio`, downstream `openshift-service-mesh/istio`).
2. Creates an isolated git worktree per **job** — either one SHA per branch (default) or **one worktree for multiple SHAs** into the same branch when you ask for **combined mode** — so your working copy is untouched.
3. Spawns parallel sub-agents (up to 4 at a time) that each:
   - Cherry-pick one commit, or **cherry-pick a series** preserving one commit per upstream SHA (combined mode).
   - Resolve merge conflicts preserving upstream intent.
   - Adapt code for the older branch (Go version, dependency versions, import paths, gateway-api migration).
   - Run relevant tests and fix failures.
   - Amend the commit with `Backport-Change` / `Backport-Reason` trailers if anything was modified.
4. Spawns a second round of read-only review agents that compare the backported
   diff against the original, flagging any unjustified divergences.
5. Reports a summary table and optionally pushes branches / creates PRs.

## Prerequisites

- An AI coding agent that supports skills/tools: [Cursor](https://cursor.com/)
  (agent mode) or [Claude Code](https://docs.anthropic.com/en/docs/claude-code).
- A local clone of the downstream repo with remotes configured for both upstream
  and downstream (any remote names work -- the skill detects them by URL).
- `git`, `go`, and `gh` (GitHub CLI) available on your PATH.

## Usage

Open the downstream repo in your agent and use agent mode. Examples:

### Single commit, single branch

> Backport abc123def into release-2.4

### Multiple commits, multiple branches

> Cherry-pick abc123def, def456abc into release-2.4, release-2.3

Without a **combined** signal, the skill generates the **cross-product**: each SHA into each branch (four backports in that example).

### Combined backport (one branch, multiple commits)

Use **explicit** combined mode so the agent does not guess:

- Keywords such as **together**, **as one branch**, **combined**, or **single branch**, with **one** target branch and **two or more** SHAs:
  > Backport abc123def def456abc together into release-2.4

- Or **bracket grouping** with a single branch:
  > `[abc123def def456abc] into release-2.4`

The skill creates **one** worktree and **one** topic branch with `git cherry-pick <sha1> <sha2> …` in **oldest-first** order (after verifying the SHAs form a linear series), preserving **one git commit per upstream SHA**. The hints script runs in `--combined` mode and writes `/tmp/backport-hints-<label>-<branch>`.

### With push and PR creation

> Backport abc123def into release-2.4, push to myfork

The push remote must be explicitly named. The skill never pushes unless you say so.

### With extra context

> Backport abc123def into release-2.4. Skip the telemetry tests, they're
> broken on this branch for unrelated reasons.

## How it works

### Remote detection

The skill runs `git remote -v` and matches URLs:

| Pattern in URL | Role |
|---|---|
| `istio/istio` | Upstream (source of commits to backport) |
| `openshift-service-mesh/istio` | Downstream (where target branches live) |

If a remote can't be determined, the skill asks you. If the SHA already exists
locally, the upstream fetch is skipped.

### Git worktrees

Each **job** gets its own worktree at
`/tmp/cherry-pick-<short-sha>-into-<branch>` for a single-SHA job, or
`/tmp/cherry-pick-<label>-into-<branch>` for combined multi-SHA jobs (`<label>` is
a short join of the SHAs or a hash prefix if the name would be too long). This means:

- Your working copy stays on whatever branch you're on.
- Multiple backports can run in parallel without interference.
- Cleanup is automatic (`git worktree remove`) after the skill finishes.

### Backport hints

Before cherry-picking, the skill runs `scripts/generate-backport-hints.sh` which
compares the source commit's context against the target branch and writes a hints
file. For combined backports, it runs `generate-backport-hints.sh --combined <label> <branch> <sha1> [sha2 ...]` and appends a section per upstream SHA. The hints cover:

- **Go version** differences between source and target.
- **Dependency deltas** for key packages (gateway-api, client-go, apimachinery).
- **Gateway API migration state** (v1beta1 vs v1 import and apiVersion usage).
- **Downstream-only files** that must not be overwritten (e.g., `istio.deps`).

The backport agent reads these hints before starting, avoiding wasted time
rediscovering branch divergences.

### Review agents

After backporting, a separate read-only agent reviews each result by comparing
the original upstream diff against the backported diff. It uses the same hints
file to distinguish expected adaptations from suspicious changes. Concerns are
surfaced in the summary -- they don't block the backport, but pairs with
concerns are not pushed until you confirm.

Things the reviewer flags:

- Dropped hunks with no explanation.
- Unrelated new code not in the original commit.
- Logic inversions or semantic changes.
- Removed or weakened test coverage.
- Changes to files not touched by the original.

### Commit message format

When the backport agent modifies code beyond a clean cherry-pick, it amends the
commit message to append trailers:

```
<original commit message>

(cherry picked from commit <sha>)

Backport-Change: converted gateway-api v1 imports to v1beta1
Backport-Reason: target branch uses gateway-api v1beta1 exclusively
```

## File structure

```
ossm-cherry-pick-backport-skill/
├── SKILL.md                              # Agent instructions (read by Cursor / Claude Code)
├── README.md                             # This file
└── scripts/
    └── generate-backport-hints.sh        # Detects branch divergences
```

## Contributing: improving the hints generator

The hints script and the agent prompt have a deliberate division of labor:

- **`generate-backport-hints.sh`** handles what can be detected cheaply with
  static analysis (Go versions, dependency deltas, import pattern counts,
  downstream-only files).
- **The agent** handles everything else through reasoning — conflict resolution,
  code adaptation, test fixes.

Every time the agent spends effort *discovering* a divergence that could have
been detected by a `git grep`, `diff`, or `go vet` invocation, that's a signal
the hints script should be improved. The agent is burning tokens rediscovering
something that a 50ms shell command could have told it upfront.

### How to find improvement opportunities

After running a backport, look at the `Backport-Change` / `Backport-Reason`
trailers the agent wrote. Also look at the review agent's output. Ask yourself:

> Could a script have predicted this change was needed *before* the cherry-pick?

If yes, add a check to `scripts/generate-backport-hints.sh`.

### Patterns to watch for

| Agent behavior | Static check to add |
|---|---|
| Rewrites `slices.Contains` or other stdlib calls that don't exist on the target Go version | Compare `go` directive in both `go.mod` files, then scan the diff for stdlib packages introduced after the target version |
| Converts imports from `pkg/foo/v2` to `pkg/foo` or vice versa | `git diff <sha> HEAD -- '*.go'` filtered to import blocks, compare import paths between trees |
| Renames files because they moved between branches | `git diff --name-status <sha> HEAD` to detect renames/moves in the changed file set |
| Changes struct literals because fields were added/removed | Compare struct definitions in changed files between source and target using `go doc` or AST grep |
| Updates hardcoded version strings in test fixtures | Grep testdata/golden files for the VERSION file content or known version patterns |
| Adjusts protobuf field names or generated code paths | Compare `.pb.go` file paths and proto package names between trees |
| Drops or rewrites feature-gated code | Detect feature gate constants that exist in source but not in target |

### Adding a new hint

1. Add a check to `scripts/generate-backport-hints.sh` that writes a line to
   `$HINTS`. Use the existing checks as examples — they all follow the pattern
   of comparing something between `HEAD` (target branch) and `$SOURCE_SHA`.
2. The hint line should be actionable: tell the agent *what* diverges and *what
   to do about it*. Example:
   ```
   stdlib: target Go 1.21 lacks slices package (source: Go 1.23). Replace slices.Contains with a manual loop.
   ```
3. The backport agent reads the entire hints file before starting. More hints =
   fewer wasted cycles, but keep each hint to one line so the file stays
   scannable.

### The feedback loop

```
run backport → read trailers/review output → spot a pattern → add hint → next backport is faster
```

Over time, the hints script gets smarter and the agent does less exploratory
work. The goal is not to eliminate the agent — it handles genuinely novel
situations — but to avoid making it re-derive the same mechanical
transformations every time.

## Limitations

- Max 4 parallel sub-agents per batch (platform limit in Cursor; Claude Code
  may differ). Larger matrices are batched automatically.
- Two worktrees can't check out the same branch simultaneously. The skill works
  around this by immediately creating a new branch in each worktree, but
  backporting the same SHA into the same branch twice will fail (same branch
  name collision).
- Combined mode requires SHAs **on one ancestral line** with a clear cherry-pick
  order; otherwise the agent must ask rather than guess.
- Test execution depends on the target branch's test infrastructure being
  functional. If tests are broken for unrelated reasons, use the extra context
  field to tell the agent to skip them.
