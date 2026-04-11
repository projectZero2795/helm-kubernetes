# Homelab Helm

Function-oriented Helm repo for a fresh Kubernetes cluster.

## Layout

```text
functions/
  monitoring/   # VictoriaMetrics-based Kubernetes monitoring
  networking/   # Traefik ingress and cross-namespace routes
scripts/
  install-helm.sh
  helm.sh       # deps, lint, template and deploy helper
.github/workflows/deploy.yml
```

## What This Deploys

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
  - `traefik.renzlab.com` to the Traefik dashboard
  - `grafana.renzlab.com` to Grafana in the `monitoring` namespace
  - `VMServiceScrape` for Traefik metrics

## Assumptions

- Your cluster has a default `StorageClass`.
- DNS for `traefik.renzlab.com` and `grafana.renzlab.com` points to the node IPs that will run Traefik.
- No other process on the Kubernetes nodes is already binding host ports `80` or `443`.
- Your GitHub Actions runner can SSH to `10.11.11.31:22` as `kubespray`.
- `kubectl` is already installed on `10.11.11.31`.
- The `kubespray` user can either access the cluster directly with `kubectl` or can use `sudo` to read `/etc/kubernetes/admin.conf`.

## Risks And Safety Notes

- Traefik uses host ports `80/443`, so it can conflict with anything else already listening on those ports.
- The Traefik dashboard is exposed. Keep it internal or add auth before exposing it broadly.
- HTTPS routes are enabled, but no certificate issuer is configured in this scaffold. Traefik will use its default certificate until you add a real TLS secret or cert resolver.
- The monitoring stack installs CRDs. Deploy `monitoring` before `networking`, because `networking` creates a `VMServiceScrape`.

## Preconditions

- `kubectl config current-context` points at the intended cluster, or set `KUBE_CONTEXT`.
- The cluster has reachable control-plane scrape endpoints if you want full kube-apiserver/controller-manager/scheduler coverage. Some distributions need value tweaks here.
- Persistent volumes can be provisioned for Grafana and VictoriaMetrics.
- GitHub repository secrets are configured:
  - `SSH_PRIVATE_KEY`
  - `SSH_KNOWN_HOSTS`
- Optional GitHub repository or environment variable:
  - `KUBE_CONTEXT`

## Safe Rollout Plan

1. Validate locally:
   - `./scripts/helm.sh deps`
   - `./scripts/helm.sh lint`
   - `./scripts/helm.sh template`
2. Test in a staging cluster first:
   - Point `KUBE_CONTEXT` to staging.
   - Deploy `monitoring` first, then `networking`.
3. Verify before production:
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
  - `helm get values monitoring -n monitoring -o yaml > monitoring.backup.yaml`
  - `helm get values networking -n networking -o yaml > networking.backup.yaml`
- Confirm the remote node can still reach the API server before you start the workflow:
  - `ssh kubespray@10.11.11.31 kubectl cluster-info`
- Roll back a failed deployment:
  - `helm rollback monitoring -n monitoring`
  - `helm rollback networking -n networking`
- The deploy helper uses `--atomic`, so Helm will auto-rollback on failed upgrades.

## Monitoring After Deployment

- Watch `kubectl get pods -A --watch` during the first rollout.
- Check Traefik logs:
  - `kubectl logs -n networking ds/networking-traefik`
- Check vmagent targets and Grafana datasource health after the first sync.

## GitHub Actions

- Pull requests run validation only.
- `main` runs validation and then deploys over SSH from the GitHub Actions runner to `10.11.11.31`.
- Helm is installed only when missing, both on the runner and on the remote node.
- The workflow expects:
  - `SSH_PRIVATE_KEY` to contain the private key for `kubespray@10.11.11.31`
  - `SSH_KNOWN_HOSTS` to contain the host key entry for `10.11.11.31`
  - Optional `KUBE_CONTEXT` if the node has multiple kube contexts configured
- If `kubectl` does not work for `kubespray`, the workflow falls back to `sudo` with `KUBECONFIG=/etc/kubernetes/admin.conf`.
