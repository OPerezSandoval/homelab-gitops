# Headlamp login via Authentik (OIDC)

Log into the Headlamp dashboard with your Authentik account, with **per-user identity
and RBAC** — the same OIDC IdP (`auth.archeflow.com`) used by ArgoCD, Grafana and
Vault. Headlamp is on the tailnet at `headlamp.balinese-pentatonic.ts.net`.

## How it works (and why there's a Talos step)

Headlamp does **not** authenticate users against itself — it takes the id_token from
Authentik and **forwards it to the Kubernetes API server** on the user's behalf. So
two things must trust Authentik:

1. **Headlamp** — reconciled by ArgoCD (chart `config.oidc` externalSecret mode + the
   `headlamp-oidc` ExternalSecret in `extras/`). Nothing manual.
2. **The Kubernetes API server** — must be told to validate Authentik-issued tokens.
   On Talos that's a `cluster.apiServer.extraArgs` change applied with `talosctl`
   (Step 3). Without it, login "succeeds" in Authentik but every cluster call is
   rejected and Headlamp shows nothing.

RBAC is by group: `extras/rbac.yaml` binds the Authentik group `headlamp-admins`
(surfaced by the API server as `oidc:headlamp-admins`) to `cluster-admin`.

> The repo PR is inert until you do Steps 1–3. Order matters: do Authentik + Vault
> before/around merge, and the Talos patch to actually grant access.

---

## Step 1 — Authentik (UI, one time)

1. **Providers → Create → OAuth2/OpenID Provider**
   - **Name**: `Headlamp`
   - **Authorization flow**: `default-provider-authorization-implicit-consent`
   - **Client type**: `Confidential`
   - **Redirect URIs** (Strict):
     - `https://headlamp.balinese-pentatonic.ts.net/oidc-callback`
   - **Signing Key**: authentik default (RS256)
   - **Scopes / property mappings**: include `openid`, `email`, `profile` **and the
     `groups` scope mapping** (same one ArgoCD/Grafana use) — the `groups` claim is
     required for the RBAC binding to match. Copy the **Client ID** and **Client Secret**.

2. **Applications → Create**
   - **Name**: `Headlamp`, **Slug**: `headlamp` (the slug is baked into the issuer URL
     `https://auth.archeflow.com/application/o/headlamp/`)
   - **Provider**: `Headlamp`

3. **Group for access + admin RBAC**
   - Create group **`headlamp-admins`** (Directory → Groups), add yourself.
   - Bind the `Headlamp` application so only `headlamp-admins` can access it.

## Step 2 — Store the client credentials in Vault (never in Git)

```sh
export VAULT_ADDR=https://vault.balinese-pentatonic.ts.net
vault login
vault kv put secret/headlamp-oidc \
  client_id="<Client ID from Authentik>" \
  client_secret="<Client Secret from Authentik>"
```

ESO syncs these into the `headlamp-oidc` Secret. (If you merge the PR before this
exists, the Headlamp pod stays pending on the missing Secret until you run it —
ArgoCD/ESO self-heal once the Vault keys are present.)

## Step 3 — Trust Authentik at the Kubernetes API server (Talos)

This is the out-of-repo prerequisite. Apply a machineconfig patch (do **not** commit
machine config to this repo). Save as `headlamp-apiserver-oidc.patch.yaml`:

```yaml
cluster:
  apiServer:
    extraArgs:
      oidc-issuer-url: https://auth.archeflow.com/application/o/headlamp/
      oidc-client-id: <Headlamp Client ID from Authentik>   # token audience — must match
      oidc-username-claim: email
      oidc-username-prefix: "oidc:"
      oidc-groups-claim: groups
      oidc-groups-prefix: "oidc:"
```

Apply (single control-plane node — this restarts kube-apiserver, expect a brief blip):

```sh
talosctl -n <control-plane-ip> patch machineconfig --patch @headlamp-apiserver-oidc.patch.yaml
```

Notes:
- `oidc-client-id` **must equal** the Headlamp Client ID (the id_token's `aud`).
- The `oidc:` prefixes mean your identity is user `oidc:<email>` and group
  `oidc:headlamp-admins` — the latter is exactly what `extras/rbac.yaml` binds.
- The API server allows only one OIDC issuer via these flags; if you later want OIDC
  for `kubectl` too, reuse this same client or move to structured auth config.

## Step 4 — Merge the PR

Merge → ArgoCD rolls Headlamp with OIDC enabled and applies the ExternalSecret + RBAC.

## Step 5 — Test

Open `https://headlamp.balinese-pentatonic.ts.net` → **Sign in** → Authentik → back.
You should land authenticated as yourself with cluster-admin. If you can log in but
see no resources / "Unauthorized", the API server isn't trusting the token yet —
recheck Step 3 (issuer URL, client-id/audience, claims).

## Security note

The Headlamp ServiceAccount is bound to `cluster-admin` (chart default,
`clusterRoleBinding.clusterRoleName`). With OIDC on, user requests use the user's own
token, but the standing SA grant is broad. Hardening (point it at a narrower
ClusterRole) is a separate change.
