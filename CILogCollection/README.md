# CILogCollection.sh

A diagnostic shell script for [Azure Monitor Container Insights](https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-overview) on AKS and Arc-enabled Kubernetes clusters. It collects logs from `ama-logs` agent pods, tests network connectivity to Azure Monitor endpoints from inside an agent pod, queries the cluster's Azure configuration (DCR / DCRA / AMPLS / daily cap), and analyzes everything for known issues — all in a single run.

---

## Prerequisites

| Tool | Required | Notes |
|---|---|---|
| `kubectl` | Yes | Must be connected to the target cluster (`az aks get-credentials ...`). The script exits early with `[FATAL]` if it cannot reach the API server. |
| `tar` | Yes | Used to package the output archive. |
| `az` CLI | Optional | Required for Azure configuration checks (`--cluster-resource-id`). |
| `python3` | Optional | Used for JSON parsing in several DCR / DCE / cap checks and JWT claim extraction in the MSI token test. |
| `curl` inside the `ama-logs` DS pod | Recommended | Required for the in-pod Managed Identity token test. The check `[SKIP]`s cleanly when `curl` is unavailable. |

---

## Usage

```bash
bash CILogCollection.sh [options]
```

### Options

| Flag | Argument | Description |
|---|---|---|
| `--workspace-id` | `<guid>` | Log Analytics Workspace ID (short GUID from workspace **Overview** in the portal). Enables workspace endpoint tests and daily cap checks. Auto-detected from the agent's environment if omitted. |
| `--region` | `<region>` | Azure region of the cluster (e.g. `eastus`, `westus2`). Enables regional control-plane endpoint tests. Auto-detected from node labels if omitted. |
| `--cluster-resource-id` | `<resource-id>` | Full AKS resource ID. Enables Azure configuration checks: auth mode, DCR/DCRA validation, DCE/AMPLS, daily ingestion cap, table activity, and **the ConfigMap-vs-DCR `ContainerLogV2` schema cross-check**. |
| `--ampls` | _(none)_ | Force Azure Monitor Private Link Scope (AMPLS) mode. Usually auto-detected via DNS resolution; use this flag if auto-detection fails. |
| `--skip-network` | _(none)_ | Skip all network connectivity tests (DNS + HTTPS + MSI token test). |
| `--skip-analysis` | _(none)_ | Skip post-collection log analysis. |
| `-h`, `--help` | _(none)_ | Print usage and exit. |

### Examples

```bash
# Minimal — auto-detects region and workspace ID
bash CILogCollection.sh

# With workspace and region for full endpoint coverage
bash CILogCollection.sh --workspace-id a1b2c3d4-5e6f-... --region eastus

# Full Azure config checks (recommended for triage tickets)
bash CILogCollection.sh \
  --cluster-resource-id /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ContainerService/managedClusters/<name>

# Behind AMPLS (private endpoints), skip network tests
bash CILogCollection.sh --ampls --skip-network
```

---

## What it does

### Phase 1 — Log Collection

Prerequisites are validated up front. The script aborts with `[FATAL]` if `kubectl` cannot reach the cluster or if `tar` is missing — it does not attempt to run checks against a disconnected context.

Collects logs from all `ama-logs` agent pods in the `kube-system` namespace:

- **Linux DaemonSet pods** (`ama-logs-*`): `mdsd.err`, `mdsd.qos`, `mdsd.info`, `mdsd.warn`, `fluent-bit-out-oms-runtime.log`, `fluent-bit*.log`, `fluentd.log`, container inventory file, process list, full `/etc/mdsd.d/` config directory, agent state directory, custom prometheus settings, and the kubelet-projected ConfigMap settings folder (`/etc/config/settings/`).
- **ReplicaSet pod** (`ama-logs-rs-*`): same set of runtime logs plus RS-specific configuration.
- **Windows DaemonSet pods** (`ama-logs-windows-*`): Windows agent event logs, fluent-bit config, and telegraf config.
- **Cluster resources**: pod / DaemonSet status, `kubectl describe` output, ConfigMaps (`container-azm-ms-agentconfig`, `container-azm-ms-aks-k8scluster`), DCR / DCRA objects, recent Kubernetes events for `ama-logs`, `top nodes` / `top pods`, node detail JSON, NetworkPolicies in `kube-system`, the `ama-logs` ServiceAccount, and the `ama-logs` Deployment YAML.

### Phase 2 — Network Connectivity

Tests DNS resolution and HTTPS reachability for all required Azure Monitor endpoints, **and** validates Managed Identity end-to-end:

| Check | When |
|---|---|
| Global ODS / OMS / agent service endpoints | Always |
| Workspace-specific ODS / OMS endpoints | `--workspace-id` provided or auto-detected |
| Regional control-plane endpoint | `--region` provided or auto-detected; **skipped in AMPLS mode** (Azure only creates a private DNS zone for the global handler endpoint, not the regional one) |
| DCE-specific handler endpoint | AMPLS mode only — hostname extracted from `mdsd.info` (`MCS redirected to endpoint` log line) and tested for DNS + HTTPS |
| **In-pod Managed Identity token test** | Always (skips cleanly if `curl` is unavailable in the DS pod) — `curl`s IMDS (`http://169.254.169.254`) from inside an `ama-logs` DaemonSet pod for a `monitor.azure.com` token, parses the returned JWT, and prints the identity in use (`clientId` / `objectId` / `resourceId`). Failures emit an `[ISSUE]` with remediation hints (NetworkPolicy/NSG blocking IMDS, hostNetwork misconfigured, kubelet identity not attached). |

> **AMPLS note:** In AMPLS mode the script always tests the standard `{workspace-id}.ods/oms.opinsights.azure.com` hostnames — not the `.privatelink.` form. The private DNS zones override resolution of the standard hostnames to private IPs, which the DNS test validates. The `.privatelink.` hostnames cause TLS failures because the certificate is issued for `*.ods.opinsights.azure.com`.

### Phase 3 — Log Analysis

Scans the collected logs and Kubernetes data and reports findings at three severity levels:

| Level | Meaning |
|---|---|
| `[OK]` | Healthy signal confirmed |
| `[INFO]` | Noteworthy but not necessarily an issue (e.g. past errors that resolved, zero-row streams that are expected, ConfigMap settings that match upstream defaults) |
| `[ISSUE]` | Active problem with remediation guidance — also rolled up at the end into `[ANALYSIS SUMMARY] N issue(s) detected` |

Checks performed:

| Check | What it validates |
|---|---|
| `mdsd.info` end-to-end pipeline proof | Confirms the agent reached AMCS, received a DCE redirect, was delivered DCR config, and obtained an ingestion ("gig") token from the DCE. Emits `[OK]` only when all four signals are present. |
| `mdsd.err` | Fatal errors, certificate failures, throttling, config parse errors. |
| `mdsd.warn` | Unexpected warnings (benign container-environment systemctl noise is filtered before evaluation). |
| `mdsd.qos` | Per-table throughput — confirms rows are reaching Azure Monitor. Distinguishes "0 rows" that are expected (e.g. `ContainerLog` when `ContainerLogV2` is the active table) from streams that genuinely should be reporting data. |
| `fluent-bit-out-oms-runtime.log` | Continuous "failed to forward data to MDSD" errors. Past-but-resolved noise is downgraded to `[INFO]`. |
| `fluent-bit*.log` | Fluent-bit's ability to read container log files from the node (permission / mount issues). |
| `fluentd.log` | The routing layer that forwards data through the processing chain. |
| Pod descriptions (DS, RS, Windows DS) — restart classifier | Distinguishes **graceful restarts** (Exit 143 + `Reason=Error` + `inotifyoutput.txt has been updated - config changed` Message, typically caused by a ConfigMap update or `kubectl rollout restart`) from **crashes** (OOMKilled, Exit 137, etc). Graceful restarts emit `[INFO]`; crashes emit `[ISSUE]`. |
| Pod descriptions — `addon-token-adapter` sidecar | Confirms the AKS-managed MSI broker sidecar is `Ready=True` and not restarting. Graceful restarts here are also downgraded to `[INFO]` with a per-pod note. |
| Pod descriptions — probe failures | Surfaces only **recent** liveness/readiness probe failures (filters out historical events that have already self-resolved). |
| Node conditions | Flags any node reporting `DiskPressure`, `MemoryPressure`, or `PIDPressure`. |
| `container-azm-ms-agentconfig` ConfigMap | Compares each section against upstream defaults. Default-matching settings emit `[INFO]` (no false-positive WARNs on a stock ConfigMap). Collection-disabling settings (e.g. stdout/stderr disabled, namespace exclusions that black-hole all telemetry) emit `[ISSUE]`. |
| **DCR ↔ ConfigMap schema cross-check** | When `--cluster-resource-id` is provided, compares the ConfigMap `containerlog_schema_version` (`v1`/`v2`) against the DCR's `enableContainerLogV2` (`true`/`false`). Mismatches emit `[ISSUE]` with reconciliation guidance — they cause logs to be written to one table while the customer queries the other. |
| `ama-logs-events.txt` | Scheduling failures, image pull errors, mount failures, addon rollout issues. |
| DaemonSet rollout coverage | Reads `cluster/daemonset-status.txt` and flags any DaemonSet (e.g. `ama-logs`, `ama-logs-windows`) where `desired ≠ ready` or `desired ≠ available`. Catches missing-pod scenarios that per-pod describe analysis misses. |
| ConfigMap mount sanity check | Verifies the kubelet actually projected the ConfigMap into the pod by inspecting `ama-logs-daemonset/settings/..YYYY_MM_DD_HH_MM_SS.<id>/`. Zero data dirs = mount failed; populated dir = mount delivered (file count surfaced for visibility). |
| `ama-logs` image age | Queries the latest MCR tag (`mcr.microsoft.com/azuremonitor/containerinsights/ciprod`) and reports how many releases behind the running image is. `[WARN]` at 1 release behind, `[ISSUE]` at several releases behind. |
| Final `[ANALYSIS SUMMARY]` | Rollup of every `[ISSUE]` raised during the run, printed at the end of `analysis-findings.log` and `Tool.log` for fast triage. |

### Phase 4 — Azure Configuration Check

When `--cluster-resource-id` is provided, the script uses `az` CLI to check:

- Container Insights add-on status (enabled / disabled).
- Authentication mode (Managed Identity vs. Legacy).
- Data Collection Rule (DCR) and association (DCRA) existence and linkage, including the Data Collection Endpoint (DCE) referenced by the DCR (if any).
- DCR **`enableContainerLogV2`** value — captured and used for the Phase 3 ConfigMap cross-check.
- DCR data streams, destinations, collection interval, and namespace filtering mode.
- Daily ingestion cap — queries `_LogOperation` for cap-hit events in the last 7 days and lists them if found.
- Table-level data activity (last record received per table). If all tables stopped at the same timestamp more than 15 minutes ago, emits an additional warning that the simultaneous cutoff is a strong daily cap indicator.
- **AMPLS mode only:** whether the Log Analytics workspace is a connected resource in the AMPLS private link scope.
- **AMPLS mode only:** whether a DCE is associated with the cluster (via the DCR or a direct DCRA) and is a connected resource in the AMPLS scope — required for configuration delivery over the private link; also checks `publicNetworkAccess` on the DCE (`Disabled` = config refresh will fail if DCE is not in scope; `Enabled` = currently working over public internet but will break if public access is later disabled).

---

## Output

All files are written to a timestamped directory and then compressed into a single archive:

```
CILogs.<YYYYMMDD>.<HHMMSS>.<cluster>/
├── Tool.log                          # Script execution log (top-level findings rollup)
├── analysis-findings.log             # Full analysis findings
├── network-connectivity.log
├── azure-config-check.log
├── cluster/
│   ├── node.txt
│   ├── node-detailed.json
│   ├── daemonset-status.txt
│   ├── pod-status.txt
│   ├── ama-logs-events.txt
│   ├── agent-version.txt
│   ├── top-nodes.txt
│   ├── top-pods-kube-system.txt
│   ├── deployment_<name>.yaml
│   ├── container-azm-ms-agentconfig.yaml
│   ├── container-azm-ms-aks-k8scluster.yaml
│   ├── ama-logs-rs-config.yaml
│   ├── network-policies.yaml
│   └── serviceaccount-ama-logs.yaml
├── ama-logs-daemonset/
│   ├── describe_<pod>.txt
│   ├── logs_<pod>.txt
│   ├── logs_<pod>_previous.txt
│   ├── process_<pod>.txt
│   ├── containerID_<pod>.txt
│   ├── fluent-bit-out-oms-runtime.log
│   ├── fluent-bit*.log
│   ├── fluentd.log
│   ├── container_<pod>.conf
│   ├── fluent-bit.conf
│   ├── telegraf.conf
│   └── settings/                     # Projected ConfigMap settings (`..YYYY_MM_DD_HH_MM_SS.<id>/`)
├── ama-logs-daemonset-mdsd/          # mdsd logs (err, qos, info, warn)
├── ama-logs-daemonset-dcr/           # DCR configchunks (.json) — what the agent actually received
├── ama-logs-daemonset-mdsd-config/   # /etc/mdsd.d/ — mdsd.xml and full config
├── ama-logs-prom-daemonset/
│   ├── logs_<pod>_prom.txt
│   ├── container_<pod>.conf
│   ├── fluent-bit.conf
│   └── telegraf.conf
├── ama-logs-prom-daemonset-mdsd/     # mdsd logs from the ama-logs-prometheus container
├── ama-logs-replicaset/
│   ├── describe_<pod>.txt
│   ├── logs_<pod>.txt
│   ├── logs_<pod>_previous.txt
│   ├── process_<pod>.txt
│   ├── kube_<pod>.conf
│   ├── fluent-bit-rs.conf
│   └── telegraf-rs.conf
├── ama-logs-replicaset-mdsd/
├── ama-logs-replicaset-dcr/
├── ama-logs-replicaset-mdsd-config/
├── ama-logs-windows-daemonset/
│   ├── describe_<pod>.txt
│   ├── logs_<pod>.txt
│   ├── process_<pod>.txt
│   └── <windows-log-files>.txt
└── ama-logs-windows-daemonset-fbit/
```

The final archive is named `CILogs.<YYYYMMDD>.<HHMMSS>.<cluster>.tgz` in the directory where the script was run.

---

## Required Permissions

### kubectl (read-only)

The script only reads from the cluster — no writes, no deletions.

| Operation | Required | Used for |
|---|---|---|
| `kubectl get nodes/pods/configmap/daemonset` | Yes | Cluster inventory and status. |
| `kubectl describe pod` | Yes | Restart / probe / sidecar analysis. |
| `kubectl exec` (read-only commands: `ps`, `ls`, `cat`, `curl`) | Yes | Process listing, file existence checks, in-pod MSI token test. |
| `kubectl cp` (from pod to local) | Yes | Pulling mdsd / fluent-bit logs and `/etc/` config out of the agent pods. |

### Azure CLI (optional, for `--cluster-resource-id` checks)

| Scope | Required role |
|---|---|
| AKS cluster resource | `Reader` |
| Log Analytics workspace | `Log Analytics Reader` |
| AMPLS scope (if `--ampls` or auto-detected) | `Reader` on the private link scope resource |
| Data Collection Endpoint (if DCE is configured) | `Reader` |
| Data Collection Rule | `Reader` |

---

## Contributing

Contributions are welcome. Please open an issue or pull request for bug reports, new check ideas, or additional endpoint coverage.
