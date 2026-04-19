# Homelab Helm

Function-oriented Helm repo for a fresh Kubernetes cluster.

## Layout

```text
functions/
  storage/      # local-path dynamic storage bootstrap
  monitoring/   # VictoriaMetrics-based Kubernetes monitoring
  networking/   # Traefik ingress and cross-namespace routes
scripts/
  install-helm.sh
  helm.sh       # deps, lint, template and deploy helper
.github/workflows/deploy.yml
.github/workflows/auto-deploy.yml
```

## What This Deploys

- `storage`
  - local-path provisioner
  - `local-path` StorageClass, marked as the cluster default
  - dynamic PV provisioning under `/opt/local-path-provisioner` on each node
- `monitoring`
  - `victoria-metrics-k8s-stack`
  - Grafana
  - VictoriaMetrics single-node storage
  - VictoriaMetrics operator and CRDs
  - kube-state-metrics
  - node-exporter
  - kubelet and control-plane scrapes enabled by the stack defaults
- `networking`
  - Traefik as a DaemonSet
  - host ports `80` and `443`
  - `traefik.renzlab.com` to the Traefik dashboard protected with basic auth
  - `grafana.renzlab.com` to Grafana in the `monitoring` namespace
  - `VMServiceScrape` for Traefik metrics

## Assumptions

- DNS for `traefik.renzlab.com` and `grafana.renzlab.com` points to the node IPs that will run Traefik.
- No other process on the Kubernetes nodes is already binding host ports `80` or `443`.
- Your GitHub Actions runner can SSH to `10.11.11.31:22` as `root`.
- `kubectl` is already installed on `10.11.11.31`.
- `/etc/kubernetes/admin.conf` exists on `10.11.11.31` for cluster access.
- Your nodes have writable disk space available under `/opt/local-path-provisioner`.

## Risks And Safety Notes

- Traefik uses host ports `80/443`, so it can conflict with anything else already listening on those ports.
- The Traefik dashboard is protected with basic auth. Store credentials only in GitHub Secrets, not in the repository.
- Grafana SMTP is configured for Gmail. Store only the Gmail app password in GitHub Secrets, not in the repository.
- HTTPS routes are enabled, but no certificate issuer is configured in this scaffold. Traefik will use its default certificate until you add a real TLS secret or cert resolver.
- The monitoring stack installs CRDs. Deploy `monitoring` before `networking`, because `networking` creates a `VMServiceScrape`.
- The `storage` function uses node-local storage. If the node holding a volume fails, that volume is gone until you restore from backup or recreate it.
- The repo marks `local-path` as the default StorageClass for this cluster. If you later adopt Longhorn, Ceph, NFS CSI, or another provisioner, switch the default intentionally.

## Preconditions

- `kubectl config current-context` points at the intended cluster, or set `KUBE_CONTEXT`.
- The cluster has reachable control-plane scrape endpoints if you want full kube-apiserver/controller-manager/scheduler coverage. Some distributions need value tweaks here.
- No existing default StorageClass is required; this repo now provisions `local-path` itself.
- GitHub repository secrets are configured:
  - `SSH_PRIVATE_KEY_B64`
  - `TRAEFIK_DASHBOARD_USERS`
  - `GRAFANA_SMTP_PASSWORD`
- Optional GitHub repository or environment variable:
  - `KUBE_CONTEXT`

## Safe Rollout Plan

1. Validate locally:
   - `./scripts/helm.sh deps`
   - `./scripts/helm.sh lint`
   - `./scripts/helm.sh template`
2. Test in a staging cluster first:
   - Point `KUBE_CONTEXT` to staging.
   - Deploy `storage` first, then `monitoring`, then `networking`.
3. Verify before production:
   - `kubectl get storageclass`
   - `kubectl get pods -n local-path-storage`
   - `kubectl get pods -n monitoring`
   - `kubectl get pods -n networking`
   - `kubectl get ingressroute,middleware -n networking`
   - `kubectl get vmservicescrape -n networking`
4. Deploy to production:
   - Run the `Homelab Helm` workflow on `main` or trigger it with `workflow_dispatch`.
5. Verify after deployment:
   - Browse `https://traefik.renzlab.com`
   - Browse `https://grafana.renzlab.com`
   - Confirm Grafana datasource `VictoriaMetrics` is healthy
   - Confirm Traefik metrics appear in Grafana

## Backups And Rollback

- Export current release values before changing production:
  - `helm get values storage -n local-path-storage -o yaml > storage.backup.yaml`
  - `helm get values monitoring -n monitoring -o yaml > monitoring.backup.yaml`
  - `helm get values networking -n networking -o yaml > networking.backup.yaml`
- Confirm the remote node can still reach the API server before you start the workflow:
  - `ssh root@10.11.11.31 KUBECONFIG=/etc/kubernetes/admin.conf kubectl cluster-info`
- Roll back a failed deployment:
  - `helm rollback storage -n local-path-storage`
  - `helm rollback monitoring -n monitoring`
  - `helm rollback networking -n networking`
- The deploy helper uses `--atomic`, so Helm will auto-rollback on failed upgrades.
- Do not uninstall `storage` while PVCs or PVs created by `local-path` still exist.

## Monitoring After Deployment

- Watch `kubectl get pods -A --watch` during the first rollout.
- Check the storage provisioner logs:
  - `kubectl logs -n local-path-storage deploy/storage-storage-provisioner`
- Check Traefik logs:
  - `kubectl logs -n networking ds/networking-traefik`
- Check vmagent targets and Grafana datasource health after the first sync.

## GitHub Actions

- Pull requests run validation only.
- The canonical deployment workflow is `.github/workflows/deploy.yml`. It supports manual `workflow_dispatch` and reusable `workflow_call`.
- `main` uses `.github/workflows/auto-deploy.yml`, which only calls the canonical deploy workflow. Automatic deployment does not maintain a separate deployment path.
- Helm is installed only when missing, both on the runner and on the remote node.
- Deploy jobs are split by function. `storage` and `networking` can run independently, and `monitoring` waits for `storage` only when storage changed.
- Deploy jobs are skipped when their function configuration did not change.
- `workflow_dispatch` can bypass change detection per function:
  - `deploy_storage=true`
  - `deploy_monitoring=true`
  - `deploy_networking=true`
- Use `workflow_dispatch` with `force_deploy_all=true` to redeploy everything regardless of changes.
- For example, to redeploy only monitoring manually, run `Homelab Helm Deploy` with `deploy_monitoring=true`.
- The workflow expects:
  - `SSH_PRIVATE_KEY_B64` to contain the base64-encoded private key for `root@10.11.11.31`
  - `TRAEFIK_DASHBOARD_USERS` to contain one or more `htpasswd` lines for Traefik basic auth, for example `admin:$2y$...`
  - `GRAFANA_SMTP_PASSWORD` to contain the Gmail app password used by Grafana SMTP
  - Optional `KUBE_CONTEXT` if the node has multiple kube contexts configured
- The workflow uses `KUBECONFIG=/etc/kubernetes/admin.conf` on the remote node by default.
- The workflow uses `StrictHostKeyChecking=accept-new`, so it will trust the first host key it sees and fail if the host key later changes.
- Grafana SMTP is configured with `smtp.gmail.com:587`, sender `projectzero2795@gmail.com`, and display name `Renz Beltran`.
