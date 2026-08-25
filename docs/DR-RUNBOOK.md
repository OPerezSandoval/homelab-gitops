# Disaster recovery runbook — `optiplex-cluster`

Single-node Talos cluster. This is what to do when it is down, and the traps
that have actually bitten, with dates.

> **Design goal, as of 2026-08-24:** a power cut should end with the cluster
> back on its own, with **no human action and the Pavilion powered off**. The
> only manual step remaining is unsealing Vault.

---

## 1. Power outage — the 60-second version

1. **Wait ~10 minutes.** Both boxes should power on by themselves (BIOS
   `Restore on AC Power Loss = Power On`). The cluster does not need the
   Pavilion in order to start.
2. **Unseal Vault** — the one manual step:
   ```bash
   kubectl -n vault exec -it vault-0 -- vault operator unseal   # x3, of 5 shares
   ```
3. **Wait 5 more minutes and do nothing.** ESO self-heals.
4. Check: `kubectl -n argo-gitops get app`

**Expected steady state:** 29 apps `Synced / Healthy`, node with **no taints**.

### Do NOT do these

All three were done during the 2026-07-07 incident and made things worse:

- **Do not delete `ClusterSecretStore/vault-backend`.** It re-validates by
  itself on ESO's next requeue (~5 min after unseal).
- **Do not delete ExternalSecrets** to "force" a resync. They clear on their
  own backoff.
- **Do not `rollout restart` the ESO controller.** That is what exposed the
  node taint and cost the most time. The cascade self-heals.

---

## 2. Triage order

**Capture node taints FIRST**, before changing anything. The 2026-07-07
incident went unexplained for weeks because the taint was removed before
anyone wrote down what it was:

```bash
kubectl get node -o jsonpath='{.items[*].spec.taints}'; echo
kubectl get nodes                    # SchedulingDisabled?
kubectl -n vault exec vault-0 -- vault status
kubectl get externalsecrets -A
kubectl -n kube-system get pod -l k8s-app=cilium
```

### Taints you may see

| Taint | Meaning |
| --- | --- |
| `node-role.kubernetes.io/control-plane` | **The old bug. Should never appear again.** `cluster.allowSchedulingOnControlPlanes` was unset, so Talos re-added it on *every boot*. Only Cilium tolerated it (`operator: Exists`), so Cilium looked fine while nothing else could schedule. Fixed 2026-08-24 via `allow-scheduling-on-controlplane.yaml`. If it returns, that patch was lost. |
| `node.cilium.io/agent-not-ready` | Normal for ~90s during a Cilium restart. Clears itself. Not a bug. |
| `node.kubernetes.io/unschedulable` | A cordon, usually from a failed `talosctl upgrade` drain. `kubectl uncordon <node>`. |
| `node.kubernetes.io/not-ready` | Normal during boot until the CNI is up. |

---

## 3. Access paths

| Path | Command | Works when |
| --- | --- | --- |
| Tailnet API proxy | `kubectl --context=tailnet ...` | Cluster is up. Dies with the API server. |
| Tailnet to the node | `talosctl -n talos-optiplex.balinese-pentatonic.ts.net ...` | **Kubernetes is broken.** Runs below k8s. |
| LAN | `kubectl` / `talosctl -e 192.168.1.86` | You are home |

Configs are at `~/.talos/config` and `~/.kube/config` on the Pavilion, with
copies on the MacBook.

- Use the **MagicDNS name**, not the IP — the tailnet IP changes if the node
  re-registers.
- `*.ts.net` names resolve **only** through Tailscale DNS. The Pavilion has
  `accept-dns=false` and cannot resolve them; use `-e <ip>` there.
- The Talos client cert **expires 2026-11-19**. Renew before then.

---

## 4. Storage layout — what depends on what

| Where | What | If the Pavilion is off |
| --- | --- | --- |
| `local-path` (node disk) | Vault, Authentik DB, Grafana | Unaffected |
| `nfs-storage` (Pavilion) | medtracker x3, n8n (**RWX**), Prometheus, Alertmanager, `vault-backups` | Stay `Pending` |

**Consequence: with the Pavilion off, monitoring and alerting do not start.**
That is why the external uptime check matters more than the in-cluster rules.

`local-path` lives on `/var`, the Talos **EPHEMERAL** partition. Despite the
name it is a normal XFS filesystem on the SSD and survives reboots and power
loss; etcd lives there too. It is destroyed only by an explicit
`talosctl reset` or a reinstall.

---

## 5. Backups

```
live      node disk (local-path) or NFS
backup    NFS on the Pavilion       vault-backup CronJob, every 6h, 14d retention
offsite   Cloudflare R2, encrypted  offsite-backup CronJob, 05:17 daily
```

**Vault archives are SEALED DATA.** Restoring one requires the same seal that
produced it — the 3-of-5 Shamir shares. **A backup without those keys restores
nothing.** Keep them offline, away from the Pavilion.

Likewise the **restic password lives in Vault**, and Vault is one of the things
being backed up. It must also be held offline, or the offsite copy is
unreadable exactly when it is needed.

Prometheus is excluded from offsite: 4.6GB of the 5.3GB total, and it is
regenerating metrics rather than records.

### Restoring

```bash
restic snapshots
restic restore latest --target /restore --include '*vault-vault-backups*'
```

Two traps, both found on 2026-08-24 by actually running a restore:

- Restoring **inside a container** needs `--exclude-xattr 'security.*'`.
  SELinux labels cannot be set there and restic treats the failure as fatal.
  Restoring **on the Pavilion as root** keeps them natively and is preferred.
- A real Vault restore must preserve **uid 100**, so it needs `CAP_CHOWN`.
  Without it you get files Vault cannot read — a restore that appears to
  succeed and leaves Vault broken.

---

## 6. Talos operations

### Upgrading

```bash
talosctl upgrade --drain=false \
  --image factory.talos.dev/metal-installer/334e798f530db5f67f1a4d2b9b5f6bf136d4e956035e8e1c92fdaf064dd7d755:v1.13.9
```

- **Always use the factory image URL.** Schematic `334e798f...` =
  `siderolabs/tailscale` + `siderolabs/intel-ucode`. Upgrading with the stock
  `ghcr.io/siderolabs/installer` **silently drops both extensions** — you lose
  node-level `talosctl` access and find out during an outage.
- **Always `--drain=false`.** On a single node draining is meaningless, and it
  *hangs forever*: CNPG creates a PDB with `minAvailable: 1`, and with one
  instance there is no replica to fail over to, so eviction is impossible.
  (`enablePDB: false` is set on `authentik-db-local` to prevent this.)
- A failed drain leaves the node **cordoned**. Uncordon before rebooting.
- `talosctl upgrade` does **not** update `machine.install.image`. It is pinned
  in `install-image-factory.yaml`; keep it current.
- `talosctl patch machineconfig --dry-run` prints the **cluster CA private
  key**. Never paste that output anywhere.

### Config patches

In `~/talos-rebuild-prep/talos/patches/` — secrets-free, except the Tailscale
one which holds an auth key when filled in.

| Patch | Purpose |
| --- | --- |
| `allow-scheduling-on-controlplane.yaml` | **Fixes the recurring outage.** Without it Talos taints the node on every boot. |
| `install-image-factory.yaml` | Pins `install.image` to the factory build |
| `local-path-kubelet-mounts.yaml` | kubelet bind mount for `/var/mnt/local-path-provisioner` |
| `tailscale-extension.yaml` | `ExtensionServiceConfig` + `TS_AUTHKEY` |

---

## 7. Traps that have actually bitten

| Trap | Detail |
| --- | --- |
| **MTU** | Cilium auto-detects MTU as the **minimum across attached devices**. Adding `tailscale0` (MTU 1280) to the node dropped the cluster from 1450 to 1280 and destroyed throughput: ArgoCD's 3.4MB bundle took **48s at 72KB/s** over a *direct LAN path*, while a DERP relay in Dallas managed 2.7MB/s. Latency and DNS looked perfect throughout — an MTU black hole only appears in bulk transfer. Now pinned `MTU: 1450`. **Adding any network interface to the node can do this again.** |
| **Completed Job pods pin PVCs** | The `pvc-protection` finalizer will not release while *any* Pod references the PVC, **including `Succeeded` ones**. The pre-migration Vault backup blocked its own migration. Delete migration/backup Jobs before PVC surgery. |
| **ArgoCD's repo cache lags the merge** | The Vault StatefulSet was built 74s *after* its PR merged and still rendered the pre-merge manifest, leaving an immutable field permanently wrong. **Confirm ArgoCD's synced revision matches `origin/main` before trusting what it built.** |
| **`prune: true` deletes old PVCs** | Once a chart stops rendering a PVC, ArgoCD removes it. Data survives (`Retain`) but rollback then needs a manual PV re-bind, not just a revert. |
| **Cilium has no auto-sync, by design** | `argocd app sync cilium` is required, and a ConfigMap change is not enough — the agent reads config at startup: `kubectl -n kube-system rollout restart ds/cilium`. Existing pods keep their old MTU until recreated. |

---

## 8. State a from-scratch rebuild will NOT restore

Everything else is in Git. These are not.

| Item | Where | Recoverable? |
| --- | --- | --- |
| **`controlplane.yaml`** — Talos machine config + PKI | offline copy | **No. Not re-mintable.** Lose it and the cluster identity is gone. |
| **Vault unseal / recovery keys** (3 of 5) | offline | **No** |
| **restic password** | Vault + offline | **No** |
| Talos `TS_AUTHKEY` | machine config | Yes — mint a new one. The current key is **single-use and spent**. |
| Tailnet `tailnet-admins` membership | Tailscale console | Yes — re-add |
| `vault-kms-creds` (if auto-unseal is adopted) | hand-made Secret | Yes — re-mint from AWS |
| ArgoCD live config | not captured in Git | Known gap |

---

## 9. Full rebuild

1. Boot Talos from the **factory image** (schematic in §6), not stock.
2. Apply `controlplane.yaml` plus every patch in §6.
3. Bootstrap ArgoCD — see `README.md`.
4. Restore Vault from the newest R2 snapshot; unseal with the offline shares.
5. Re-add the tailnet group membership and mint a fresh Talos auth key.
6. See `~/talos-rebuild-prep/MIGRATION_CHECKLIST.md`.

---

## 10. Acceptance test

Not yet performed. Do it deliberately, on a weekday, while home:

> With the **Pavilion powered off**, pull power from the Optiplex. Restore
> power. Walk away. Within ~10 minutes, from your phone over Tailscale,
> `argocd` should show every app Healthy except the NFS-backed ones —
> medtracker x3, n8n, Prometheus, Alertmanager — plus Vault awaiting its
> manual unseal.

**A DR process you have not rehearsed is a hypothesis, not a process.**
