# Policy attached to the Vault OIDC "default" role — everyone who logs in via
# Authentik (i.e. members of the `vault-admins` Authentik group, which is what
# gates access to the Vault application) gets full admin.
#
# Access is gated in Authentik (application → group binding), NOT here: only
# users allowed to open the Vault application can obtain a token at all, and
# once they do they are an operator. If you later want tiered access, split this
# into multiple policies and map Authentik groups → policies via the OIDC role's
# `groups_claim` + separate roles.

path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "patch", "sudo"]
}
