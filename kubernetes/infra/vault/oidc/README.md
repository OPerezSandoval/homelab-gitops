# Vault login via Authentik (OIDC)

Log into Vault (UI + CLI) with your Authentik account, the same SSO pattern used
for ArgoCD and Grafana. Authentik is the IdP at `auth.archeflow.com`; Vault is
reachable on the tailnet at `vault.balinese-pentatonic.ts.net`.

## Why this is a runbook, not a reconciled manifest

Everything else in this repo is applied by ArgoCD, but Vault auth methods are
**runtime configuration** written through the Vault API *after unseal* — they are
not Kubernetes objects, so there is nothing for kustomize/ArgoCD to reconcile.
Vault here also comes up **sealed** and is unsealed by hand with offline keys, so
there is deliberately no privileged Vault token sitting in the cluster for a Job
or operator to use. This bootstrap therefore lives in the repo as
code + a runbook you run once, right after an unseal.

(If we ever want this reconciled: add `redhat-cop/vault-config-operator` and
express the mount/config/role as CRs in `extras/`. That is heavier — it needs its
own Kubernetes→Vault auth path — and overkill for a one-time bootstrap on a
single-node homelab, so we keep the runbook.)

Files:
- `admins-policy.hcl` — the Vault policy granted to OIDC logins.
- `setup-oidc.sh` — idempotent bootstrap (enables + configures the `oidc` method).

---

## Step 1 — Authentik (UI, one time)

Directory / Applications, as an Authentik admin:

1. **Providers → Create → OAuth2/OpenID Provider**
   - **Name**: `Vault`
   - **Authorization flow**: `default-provider-authorization-implicit-consent`
   - **Client type**: `Confidential`
   - **Redirect URIs** (Strict) — add both, one per line:
     - `https://vault.balinese-pentatonic.ts.net/ui/vault/auth/oidc/oidc/callback`
     - `http://localhost:8250/oidc/callback`
   - **Signing Key**: the default authentik self-signed cert (RS256)
   - **Scopes**: leave the defaults (`openid`, `email`, `profile`)
   - Save, then copy the generated **Client ID** and **Client Secret**.

2. **Applications → Create**
   - **Name**: `Vault`, **Slug**: `vault` (the slug MUST be `vault` — it is baked
     into the discovery URL `https://auth.archeflow.com/application/o/vault/`)
   - **Provider**: `Vault`
   - Save.

3. **Gate access with a group** (this is what decides who can log in):
   - Create group `vault-admins` (Directory → Groups) if it doesn't exist and add
     yourself.
   - On the `Vault` application, set **Bindings** so only `vault-admins` can access
     it (or set the application's *Policy engine* accordingly). Anyone not bound
     cannot obtain a Vault token.

> The two redirect URIs are Vault's UI callback and the `vault login` CLI
> localhost callback. Both are required.

## Step 2 — Store the client credentials in Vault (never in Git)

With Vault unsealed and an admin token:

```sh
export VAULT_ADDR=https://vault.balinese-pentatonic.ts.net
vault login                          # paste admin / root token
vault kv put secret/vault-oidc \
  client_id="<Client ID from Authentik>" \
  client_secret="<Client Secret from Authentik>"
```

## Step 3 — Configure the OIDC auth method

```sh
./setup-oidc.sh
```

The script reads the client credentials back out of `secret/vault-oidc`, writes
the `admins` policy, enables `auth/oidc`, and creates the `default` role. It is
idempotent — re-run it any time (e.g. after rotating the client secret in
Step 2). Equivalent manual commands are in the script if you prefer to paste them.

## Step 4 — Test

- **UI**: open `https://vault.balinese-pentatonic.ts.net`, pick method **OIDC**,
  leave role blank (uses `default`), Sign in → redirects to Authentik → back.
- **CLI**:
  ```sh
  vault login -method=oidc role=default
  ```
  Opens a browser to Authentik, then drops a token in your shell.

## Rotating the client secret

Regenerate the secret in Authentik → re-run Step 2 (`vault kv put …`) → re-run
`./setup-oidc.sh`. No repo change needed.

## What each user gets

Everyone who logs in receives the `admins` policy (full operator). Access is
restricted purely by Authentik group membership on the `Vault` application. For
tiered access later, map Authentik groups → Vault policies via the role's
`groups_claim` and add per-group roles/policies.
