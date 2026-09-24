#!/usr/bin/env bash
set -Eeuo pipefail

secret_pattern='-----BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY-----|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|dckr_pat_[A-Za-z0-9_-]{20,}'

if git grep -nIE -e "$secret_pattern" -- ':!scripts/check-secrets.sh'; then
  echo "Possible private key or access token found in tracked files." >&2
  exit 1
fi

for forbidden in \
  inventories/production/hosts.yml \
  inventories/bootstrap/hosts.yml \
  inventories/production/vault.yml; do
  if git ls-files --error-unmatch "$forbidden" >/dev/null 2>&1; then
    echo "Production-local file must not be tracked: $forbidden" >&2
    exit 1
  fi
done

echo "No common committed secret formats detected."
