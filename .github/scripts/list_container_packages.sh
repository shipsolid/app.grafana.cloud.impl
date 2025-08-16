#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN not set}"    # must be a PAT
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT missing}"
: "${GITHUB_ENV:?GITHUB_ENV missing}"

# Inputs (may be empty under set -u, so use :-)
OWNER="${OWNER:-}"
SCOPE="${SCOPE:-}"          # expected values: "", "user", "org"
PKG_FILTER="${PKG_FILTER:-}"

ME_LOGIN="$(gh api /user --jq .login)"
echo "== Authenticated as: ${ME_LOGIN}"

# Helper: write outputs
write_outputs() {
  local pkg_base="$1"; shift
  local -a arr=( "$@" )
  # packages (multiline)
  {
    echo "packages<<EOF"
    printf "%s\n" "${arr[@]}"
    echo "EOF"
  } >> "${GITHUB_OUTPUT}"
  # PKG_BASE (env for later steps)
  echo "PKG_BASE=${pkg_base}" >> "${GITHUB_ENV}"
}

# Try list helper -> returns 0 and prints names if any; 1 otherwise
try_list() {
  local list_path="$1"
  gh api -H "Accept: application/vnd.github+json" --paginate "${list_path}" --jq '.[].name' 2>/dev/null | sort -u
}

# 1) Resolve default OWNER/SCOPE
if [[ -z "${OWNER}" ]]; then
  echo "OWNER not provided; defaulting to user login: ${ME_LOGIN}"
  OWNER="${ME_LOGIN}"
fi
if [[ -z "${SCOPE}" ]]; then
  if [[ "${OWNER}" == "${ME_LOGIN}" ]]; then
    SCOPE="user"
  else
    SCOPE="org"
  fi
fi
echo "Using SCOPE=${SCOPE}, OWNER=${OWNER}"

packages=()
PKG_BASE=""

if [[ "${SCOPE}" == "user" ]]; then
  # Prefer explicit /users/<login>
  echo "== Listing via /users/${OWNER}"
  mapfile -t packages < <(try_list "/users/${OWNER}/packages?package_type=container" || true)
  PKG_BASE="/users/${OWNER}/packages/container"

  # If OWNER is token owner and nothing found, try /user
  if [[ "${#packages[@]}" -eq 0 && "${OWNER}" == "${ME_LOGIN}" ]]; then
    echo "No packages via /users/${ME_LOGIN}; trying /user…"
    mapfile -t packages < <(try_list "/user/packages?package_type=container" || true)
    PKG_BASE="/user/packages/container"
  fi

else
  # org scope: need ORG LOGIN, not ID. If OWNER provided, try that; otherwise iterate memberships.
  candidates=()
  if [[ -n "${OWNER}" ]]; then
    candidates+=( "${OWNER}" )
  else
    :
  fi

  # Always append memberships (unique)
  mapfile -t memberships < <(gh api /user/memberships/orgs --jq '.[].organization.login' 2>/dev/null || true)
  for o in "${memberships[@]:-}"; do
    # de-dup
    if [[ " ${candidates[*]} " != *" ${o} "* ]]; then
      candidates+=( "${o}" )
    fi
  done

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "No org memberships detected for this token."
  fi

  echo "== Org candidates: ${candidates[*]:-(none)}"
  for org in "${candidates[@]:-}"; do
    echo "== Trying org: ${org}"
    mapfile -t packages < <(try_list "/orgs/${org}/packages?package_type=container" || true)
    if [[ "${#packages[@]}" -gt 0 ]]; then
      OWNER="${org}"
      PKG_BASE="/orgs/${org}/packages/container"
      break
    fi
  done
fi

echo "Found ${#packages[@]} container package(s) total before filter."
if [[ -n "${PKG_FILTER}" && "${#packages[@]}" -gt 0 ]]; then
  mapfile -t packages < <(printf "%s\n" "${packages[@]}" | grep -i -- "${PKG_FILTER}" || true)
  echo "After filter '${PKG_FILTER}', ${#packages[@]} remain."
fi

if [[ "${#packages[@]}" -eq 0 ]]; then
  echo "No matching packages."
  # still export PKG_BASE so downstream steps can know which base to use (could be empty)
  echo "packages=" >> "${GITHUB_OUTPUT}"
  echo "PKG_BASE=${PKG_BASE}" >> "${GITHUB_ENV}"
  exit 0
fi

printf "%s\n" "${packages[@]}" | tee packages.txt
write_outputs "${PKG_BASE}" "${packages[@]}"
