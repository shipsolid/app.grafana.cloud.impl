#!/usr/bin/env bash
set -euo pipefail
command -v gh >/dev/null || { echo "gh CLI is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

GH_TOKEN="${GH_TOKEN:?GH_TOKEN not set}"
SCOPE="${SCOPE:-user}"
OWNER="${OWNER:-shipsolid}"
PKG_FILTER="${PKG_FILTER:-}"
KEEP_LATEST="${KEEP_LATEST:-0}"
OLDER_THAN_DAYS="${OLDER_THAN_DAYS:-0}"
PKG_BASE="${PKG_BASE:-}"

# ---- helpers (NEW: URL-encode) --------------------------------------------
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

detect_pkg_base() {
  local pkg="$1"
  local pkg_enc; pkg_enc="$(urlenc "$pkg")"
  local owner_login="${OWNER:-}"
  local candidates=(
    "/users/${owner_login}/packages/container"
    "/user/packages/container"
    "/orgs/${owner_login}/packages/container"
  )
  for base in "${candidates[@]}"; do
    if [[ "$base" =~ ^/users/|^/orgs/ ]] && [[ -z "${owner_login}" ]]; then
      continue
    fi
    if gh api -H "Accept: application/vnd.github+json" \
         "${base}/${pkg_enc}/versions?per_page=1" >/dev/null 2>&1; then
      echo "$base"
      return 0
    fi
  done
  return 1
}

validate_or_detect_pkg_base() {
  local first_pkg="$1"
  local first_enc; first_enc="$(urlenc "$first_pkg")"
  if [[ -n "${PKG_BASE}" ]]; then
    if gh api -H "Accept: application/vnd.github+json" \
         "${PKG_BASE}/${first_enc}/versions?per_page=1" >/dev/null 2>&1; then
      echo "Using provided PKG_BASE=${PKG_BASE}"
      return 0
    fi
    echo "Provided PKG_BASE invalid for '${first_pkg}', re-detecting…" >&2
  else
    echo "PKG_BASE not provided; detecting…" >&2
  fi

  local detected
  if detected="$(detect_pkg_base "${first_pkg}")"; then
    PKG_BASE="${detected}"
    echo "Detected PKG_BASE=${PKG_BASE}"
    return 0
  else
    echo "ERROR: Could not determine PKG_BASE for '${first_pkg}'" >&2
    return 1
  fi
}

fetch_versions_json() {
  local pkg="$1"
  local pkg_enc; pkg_enc="$(urlenc "$pkg")"
  gh api -H "Accept: application/vnd.github+json" --paginate \
     "${PKG_BASE}/${pkg_enc}/versions?per_page=100"
}

# ---- load packages ---------------------------------------------------------
if [[ -s "packages.txt" ]]; then
  mapfile -t PACKAGES < packages.txt
elif [[ -n "${PACKAGES:-}" ]]; then
  printf "%s\n" "${PACKAGES}" > packages.txt
  mapfile -t PACKAGES < packages.txt
else
  echo "No packages.txt or PACKAGES env provided; nothing to preview."
  exit 0
fi

# ---- header ----------------------------------------------------------------
{
  echo "# GHCR Cleanup Preview"
  echo "- Scope: ${SCOPE}"
  echo "- Owner: ${OWNER}"
  echo "- Filter: '${PKG_FILTER}'"
  echo "- Keep latest: ${KEEP_LATEST}"
  echo "- Older than (days): ${OLDER_THAN_DAYS}"
  echo ""
} > PREVIEW.md

# ---- ensure PKG_BASE is valid ---------------------------------------------
first_pkg="${PACKAGES[0]}"
validate_or_detect_pkg_base "${first_pkg}" || exit 1

# ---- per-package loop ------------------------------------------------------
for pkg in "${PACKAGES[@]}"; do
  [[ -z "${pkg}" ]] && continue
  echo "Processing package: ${pkg}"

  if ! versions_json="$(fetch_versions_json "${pkg}")"; then
    echo "WARN: ${PKG_BASE}/(encoded:${pkg})/versions failed; re-detecting base…" >&2
    if PKG_BASE="$(detect_pkg_base "${pkg}")"; then
      echo "Re-detected PKG_BASE=${PKG_BASE}"
      versions_json="$(fetch_versions_json "${pkg}")"
    else
      echo "ERROR: Could not access versions for '${pkg}' — skipping." >&2
      {
        echo "## Package: \`${pkg}\`"
        echo "- Total versions: 0"
        echo "- Versions selected to delete: 0"
        echo ""
      } >> PREVIEW.md
      continue
    fi
  fi

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

  to_delete="$(echo "${versions_sorted}" | jq --argjson keep "${KEEP_LATEST}" --argjson age "${OLDER_THAN_DAYS}" '
    def too_old($days):
      if $days == 0 then true
      else ((now - (.created_at | fromdateiso8601)) / 86400 | floor) >= $days
      end;
    to_entries
    | map(select(.key >= $keep))
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
