#!/usr/bin/env bash
set -euo pipefail

# Append hint blocks for one upstream commit tree (SOURCE_SHA) to HINTS.
append_hints_for_sha() {
  local SOURCE_SHA="$1"
  local SHORT="${SOURCE_SHA:0:8}"

  {
    echo ""
    echo "=== upstream ${SHORT} ==="
  } >> "$HINTS"

  # Go version
  local local_go source_go
  local_go=$(sed -n 's/^go //p' go.mod | head -1)
  source_go=$(git show "${SOURCE_SHA}:go.mod" | sed -n 's/^go //p' | head -1)
  if [ "$local_go" != "$source_go" ]; then
    echo "go-version: ${local_go} (source: ${source_go})" >> "$HINTS"
  else
    echo "go-version: ${local_go}" >> "$HINTS"
  fi

  # Key dependency deltas
  local dep local_ver source_ver
  for dep in "sigs.k8s.io/gateway-api" "k8s.io/client-go" "k8s.io/apimachinery"; do
    local_ver=$(grep -m1 "	${dep} " go.mod | awk '{print $2}' || true)
    source_ver=$(git show "${SOURCE_SHA}:go.mod" | grep -m1 "	${dep} " | awk '{print $2}' || true)
    if [ -n "$local_ver" ] && [ "$local_ver" != "$source_ver" ]; then
      echo "dep: ${dep} ${local_ver} (source: ${source_ver})" >> "$HINTS"
    fi
  done

  # Gateway API version migration state
  count_refs() {
    git grep -c "$2" "$1" -- ${3:+"$3"} 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}'
  }
  local local_beta source_beta local_apiver_beta source_apiver_beta
  local_beta=$(count_refs HEAD 'gateway-api/apis/v1beta1' '*.go')
  source_beta=$(count_refs "${SOURCE_SHA}" 'gateway-api/apis/v1beta1' '*.go')
  if [ "$local_beta" -gt "$source_beta" ]; then
    echo "gateway-api: this branch imports gateway-api/apis/v1beta1 (${local_beta} files); source has ${source_beta}. Incoming code may use gateway-api/apis/v1 imports — convert to v1beta1." >> "$HINTS"
  fi
  local_apiver_beta=$(count_refs HEAD 'gateway\.networking\.k8s\.io/v1beta1')
  source_apiver_beta=$(count_refs "${SOURCE_SHA}" 'gateway\.networking\.k8s\.io/v1beta1')
  if [ "$local_apiver_beta" -gt "$source_apiver_beta" ]; then
    echo "gateway-api: this branch uses apiVersion gateway.networking.k8s.io/v1beta1 (${local_apiver_beta} refs); source has ${source_apiver_beta}. Incoming YAML/testdata may use v1 — convert to v1beta1." >> "$HINTS"
  fi

  # Downstream-only files/dirs (relative to this SOURCE_SHA tree)
  echo "downstream-only: istio.deps (never overwrite)" >> "$HINTS"
  comm -23 \
    <(git ls-tree --name-only HEAD | sort) \
    <(git ls-tree --name-only "${SOURCE_SHA}" | sort) \
  | while read -r f; do
    [ "$f" = "istio.deps" ] && continue
    echo "downstream-only: ${f}" >> "$HINTS"
  done
}

usage() {
  echo "usage: $0 <source-sha> <branch-name>" >&2
  echo "   or: $0 --combined <label> <branch-name> <sha1> [sha2 ...]" >&2
  exit 1
}

if [ "${1:-}" = "--combined" ]; then
  shift
  [ "$#" -ge 3 ] || usage
  LABEL="${1:?}"
  BRANCH="${2:?}"
  shift 2
  HINTS="/tmp/backport-hints-${LABEL}-${BRANCH}"
  {
    echo "combined-backport label: ${LABEL}"
    echo "target branch name: ${BRANCH}"
    echo "upstream SHAs: $*"
  } > "$HINTS"
  for sha in "$@"; do
    append_hints_for_sha "$sha"
  done
else
  [ "$#" -eq 2 ] || usage
  SOURCE_SHA="${1:?}"
  BRANCH="${2:?}"
  SHORT="${SOURCE_SHA:0:8}"
  HINTS="/tmp/backport-hints-${SHORT}-${BRANCH}"
  > "$HINTS"
  append_hints_for_sha "$SOURCE_SHA"
fi

echo "Wrote $HINTS:"
cat "$HINTS"
