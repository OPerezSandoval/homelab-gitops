#!/usr/bin/env bash
# Bootstrap Authentik OIDC login for Vault. Idempotent — safe to re-run.
#
# This is a ONE-TIME runtime bootstrap, not a reconciled resource: Vault comes
# up sealed and is unsealed by hand with offline keys, so its auth methods are
# configured out-of-band right after unseal (there is no privileged Vault token
# living in the cluster for an operator/Job to use). Run this from a trusted
# workstation once, after completing the Authentik steps in README.md.
#
# Prereqs:
#   - Vault is unsealed and you are logged in as an admin (root token or equiv):
#       export VAULT_ADDR=https://vault.balinese-pentatonic.ts.net
#       vault login            # paste admin/root token
#   - The Authentik provider/application exist (see README.md) and the client
#     credentials have been written to Vault KV:
#       vault kv put secret/vault-oidc client_id=... client_secret=...
#
# The client_id/client_secret are read from Vault KV so no secret ever touches
# this repo, your shell history, or a CLI arg.

set -euo pipefail

VAULT_HOST="${VAULT_HOST:-vault.balinese-pentatonic.ts.net}"
AUTHENTIK_APP_SLUG="${AUTHENTIK_APP_SLUG:-vault}"
DISCOVERY_URL="https://auth.archeflow.com/application/o/${AUTHENTIK_APP_SLUG}/"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Reading OIDC client credentials from Vault KV (secret/vault-oidc)"
CLIENT_ID="$(vault kv get -field=client_id secret/vault-oidc)"
CLIENT_SECRET="$(vault kv get -field=client_secret secret/vault-oidc)"

echo "==> Writing 'admins' policy"
vault policy write admins "${SCRIPT_DIR}/admins-policy.hcl"

echo "==> Enabling the oidc auth method (skipped if already enabled)"
if ! vault auth list -format=json | grep -q '"oidc/"'; then
  vault auth enable oidc
else
  echo "    oidc/ already enabled"
fi

echo "==> Configuring auth/oidc/config"
vault write auth/oidc/config \
  oidc_discovery_url="${DISCOVERY_URL}" \
  oidc_client_id="${CLIENT_ID}" \
  oidc_client_secret="${CLIENT_SECRET}" \
  default_role="default"

echo "==> Configuring auth/oidc/role/default"
vault write auth/oidc/role/default \
  user_claim="sub" \
  allowed_redirect_uris="https://${VAULT_HOST}/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
  policies="admins" \
  oidc_scopes="openid,profile,email" \
  ttl="1h"

echo "==> Done. Test the UI at https://${VAULT_HOST} (method: OIDC) or CLI:"
echo "    vault login -method=oidc role=default"
