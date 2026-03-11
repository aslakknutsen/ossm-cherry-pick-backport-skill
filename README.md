# OSSM Cherry-Pick Backport Skill

An AI coding agent skill that backports commits into downstream release branches
using cherry-pick, with AI-assisted conflict resolution, code adaptation, and
automated review. Works with Cursor and Claude Code.

## What it does

Given one or more commit SHAs and one or more target branches, the skill:

1. Detects your git remotes (upstream `istio/istio`, downstream `openshift-service-mesh/istio`).
2. Creates an isolated git worktree per (SHA, branch) pair so your working copy is untouched.
3. Spawns parallel sub-agents (up to 4 at a time) that each:
   - Cherry-pick the commit into the target branch.
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

The skill generates the cross-product: each SHA into each branch.

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

Each (SHA, branch) pair gets its own worktree at
`/tmp/cherry-pick-<short-sha>-into-<branch>`. This means:

- Your working copy stays on whatever branch you're on.
- Multiple backports can run in parallel without interference.
- Cleanup is automatic (`git worktree remove`) after the skill finishes.

### Backport hints

Before cherry-picking, the skill runs `scripts/generate-backport-hints.sh` which
compares the source commit's context against the target branch and writes a hints
file. The hints cover:

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

## Limitations

- Max 4 parallel sub-agents per batch (platform limit in Cursor; Claude Code
  may differ). Larger matrices are batched automatically.
- Two worktrees can't check out the same branch simultaneously. The skill works
  around this by immediately creating a new branch in each worktree, but
  backporting the same SHA into the same branch twice will fail (same branch
  name collision).
- Test execution depends on the target branch's test infrastructure being
  functional. If tests are broken for unrelated reasons, use the extra context
  field to tell the agent to skip them.
