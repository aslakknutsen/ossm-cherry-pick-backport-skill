#!/usr/bin/env bash
set -euo pipefail

SOURCE_SHA="${1:?usage: $0 <source-sha> <branch-name>}"
BRANCH="${2:?usage: $0 <source-sha> <branch-name>}"
SHORT="${SOURCE_SHA:0:8}"
HINTS="/tmp/backport-hints-${SHORT}-${BRANCH}"

> "$HINTS"

# Go version
local_go=$(sed -n 's/^go //p' go.mod | head -1)
source_go=$(git show "${SOURCE_SHA}:go.mod" | sed -n 's/^go //p' | head -1)
if [ "$local_go" != "$source_go" ]; then
  echo "go-version: ${local_go} (source: ${source_go})" >> "$HINTS"
else
  echo "go-version: ${local_go}" >> "$HINTS"
fi

# Key dependency deltas
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

# Downstream-only files/dirs
echo "downstream-only: istio.deps (never overwrite)" >> "$HINTS"
comm -23 \
  <(git ls-tree --name-only HEAD | sort) \
  <(git ls-tree --name-only "${SOURCE_SHA}" | sort) \
| while read -r f; do
  [ "$f" = "istio.deps" ] && continue
  echo "downstream-only: ${f}" >> "$HINTS"
done

echo "Wrote $HINTS:"
cat "$HINTS"
