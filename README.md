# Homelab Helm

Function-oriented Helm repo for a fresh Kubernetes cluster.

## Layout

```text
functions/
  monitoring/   # VictoriaMetrics-based Kubernetes monitoring
  networking/   # Traefik ingress and cross-namespace routes
scripts/
  helm.sh       # deps, lint, template and deploy helper
bitbucket-pipelines.yml
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
- Your Bitbucket self-hosted runner is a Linux Shell runner with `helm`, `kubectl`, and cluster access already configured.

## Risks And Safety Notes

- Traefik uses host ports `80/443`, so it can conflict with anything else already listening on those ports.
- The Traefik dashboard is exposed. Keep it internal or add auth before exposing it broadly.
- HTTPS routes are enabled, but no certificate issuer is configured in this scaffold. Traefik will use its default certificate until you add a real TLS secret or cert resolver.
- The monitoring stack installs CRDs. Deploy `monitoring` before `networking`, because `networking` creates a `VMServiceScrape`.

## Preconditions

- `kubectl config current-context` points at the intended cluster, or set `KUBE_CONTEXT`.
- The cluster has reachable control-plane scrape endpoints if you want full kube-apiserver/controller-manager/scheduler coverage. Some distributions need value tweaks here.
- Persistent volumes can be provisioned for Grafana and VictoriaMetrics.

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
   - `./scripts/helm.sh deploy`
5. Verify after deployment:
   - Browse `https://traefik.renzlab.com`
   - Browse `https://grafana.renzlab.com`
   - Confirm Grafana datasource `VictoriaMetrics` is healthy
   - Confirm Traefik metrics appear in Grafana

## Backups And Rollback

- Export current release values before changing production:
  - `helm get values monitoring -n monitoring -o yaml > monitoring.backup.yaml`
  - `helm get values networking -n networking -o yaml > networking.backup.yaml`
- Roll back a failed deployment:
  - `helm rollback monitoring -n monitoring`
  - `helm rollback networking -n networking`
- The deploy helper uses `--atomic`, so Helm will auto-rollback on failed upgrades.

## Monitoring After Deployment

- Watch `kubectl get pods -A --watch` during the first rollout.
- Check Traefik logs:
  - `kubectl logs -n networking ds/networking-traefik`
- Check vmagent targets and Grafana datasource health after the first sync.

## Bitbucket Pipeline

- Pull requests run validation only.
- `main` runs validation and then deploys to the cluster from the self-hosted runner.
- If you use a Docker-based runner instead of a Linux Shell runner, adjust `bitbucket-pipelines.yml` to provide an image plus kubeconfig injection.

