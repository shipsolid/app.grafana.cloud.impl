#!/usr/bin/env bash
set -euo pipefail

# Requirements
command -v gh >/dev/null || { echo "gh CLI is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

# Inputs via env (use defaults for set -u safety)
GH_TOKEN="${GH_TOKEN:?GH_TOKEN not set}"           # PAT with read:packages
SCOPE="${SCOPE:-}"
OWNER="${OWNER:-}"
PKG_FILTER="${PKG_FILTER:-}"
KEEP_LATEST="${KEEP_LATEST:-0}"                    # integer
OLDER_THAN_DAYS="${OLDER_THAN_DAYS:-0}"            # integer
PKG_BASE="${PKG_BASE:-}"                           # e.g. /users/<login>/packages/container, /orgs/<org>/packages/container

# Packages source:
# - Prefer packages.txt created by the list step
# - Fallback to PACKAGES (multiline) env if provided
if [[ -s "packages.txt" ]]; then
  mapfile -t PACKAGES < packages.txt
elif [[ -n "${PACKAGES:-}" ]]; then
  printf "%s\n" "${PACKAGES}" > packages.txt
  mapfile -t PACKAGES < packages.txt
else
  echo "No packages.txt or PACKAGES env provided; nothing to preview."
  exit 0
fi

# Header
{
  echo "# GHCR Cleanup Preview"
  echo "- Scope: ${SCOPE}"
  echo "- Owner: ${OWNER}"
  echo "- Filter: '${PKG_FILTER}'"
  echo "- Keep latest: ${KEEP_LATEST}"
  echo "- Older than (days): ${OLDER_THAN_DAYS}"
  echo ""
} > PREVIEW.md

# Iterate packages
for pkg in "${PACKAGES[@]}"; do
  [[ -z "${pkg}" ]] && continue

  echo "Processing package: ${pkg}"

  # Fetch all versions (paginated)
  versions_json="$(gh api -H "Accept: application/vnd.github+json" --paginate "${PKG_BASE}/${pkg}/versions?per_page=100")"

  # Sort newest->oldest and reduce fields
  versions_sorted="$(echo "${versions_json}" | jq -r '
    sort_by(.created_at) | reverse |
    map({
      id: .id,
      created_at: .created_at,
      tags: (.metadata.container.tags // [])
    })
  ')"

  total="$(echo "${versions_sorted}" | jq 'length')"

  {
    echo "## Package: \`${pkg}\`"
    echo "- Total versions: ${total}"
  } >> PREVIEW.md

  # Compute candidates to delete:
  # - Skip first KEEP_LATEST entries (keep newest by position)
  # - If OLDER_THAN_DAYS > 0, only include versions whose age >= OLDER_THAN_DAYS
  to_delete="$(echo "${versions_sorted}" | jq --argjson keep "${KEEP_LATEST}" --argjson age "${OLDER_THAN_DAYS}" '
    def too_old($days):
      if $days == 0 then true
      else ((now - (.created_at | fromdateiso8601)) / 86400 | floor) >= $days
      end;

    to_entries
    | map(select(.key >= $keep))                 # drop the first N (keep latest)
    | map(select( ($age == 0) or ( .value | too_old($age) ) ))
    | map(.value)
  ')"

  del_count="$(echo "${to_delete}" | jq 'length')"
  echo "- Versions selected to delete: ${del_count}" >> PREVIEW.md

  if [[ "${del_count}" -gt 0 ]]; then
    {
      echo ""
      echo "| Version ID | created_at | tags |"
      echo "|---|---|---|"
      echo "${to_delete}" | jq -r '.[] | "| \(.id) | \(.created_at) | \((.tags | join(","))) |"'
      echo ""
    } >> PREVIEW.md
  fi
done

echo "==== PREVIEW ===="
cat PREVIEW.md
echo "Preview complete."
