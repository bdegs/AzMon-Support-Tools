# CILogCollection.sh

A diagnostic shell script for [Azure Monitor Container Insights](https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-overview) on AKS and Arc-enabled Kubernetes clusters. It collects logs from `ama-logs` agent pods, tests network connectivity to Azure Monitor endpoints, and analyzes the collected logs for common known issues — all in a single run.

---

## Prerequisites

| Tool | Required | Notes |
|---|---|---|
| `kubectl` | Yes | Must be connected to the target cluster (`az aks get-credentials ...`) |
| `tar` | Yes | Used to package the output archive |
| `az` CLI | Optional | Required for Azure configuration checks (`--cluster-resource-id`) |
| `python3` | Optional | Used for certain log parsing steps |

---

## Usage

```bash
bash CILogCollection.sh [options]
```

### Options

| Flag | Argument | Description |
|---|---|---|
| `--workspace-id` | `<guid>` | Log Analytics Workspace ID (short GUID from workspace Overview in the portal). Enables workspace endpoint tests and daily cap checks. Auto-detected if omitted. |
| `--region` | `<region>` | Azure region of the cluster (e.g. `eastus`, `westus2`). Enables regional control-plane endpoint tests. Auto-detected from node labels if omitted. |
| `--cluster-resource-id` | `<resource-id>` | Full AKS resource ID. Enables Azure configuration checks: authentication mode, DCR/DCRA validation, and daily ingestion cap query. |
| `--ampls` | _(none)_ | Force Azure Monitor Private Link Scope (AMPLS) mode. Usually auto-detected via DNS resolution; use this flag if auto-detection fails. |
| `--skip-network` | _(none)_ | Skip all network connectivity tests (DNS + HTTPS checks). |
| `--skip-analysis` | _(none)_ | Skip post-collection log analysis. |
| `-h`, `--help` | _(none)_ | Print usage and exit. |

### Examples

```bash
# Minimal — auto-detects region and workspace ID
bash CILogCollection.sh

# With workspace and region for full endpoint coverage
bash CILogCollection.sh --workspace-id a1b2c3d4-5e6f-... --region eastus

# Full Azure config checks
bash CILogCollection.sh \
  --cluster-resource-id /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ContainerService/managedClusters/<name>

# Behind AMPLS (private endpoints), skip network tests
bash CILogCollection.sh --ampls --skip-network
```

---

## What it does

### Phase 1 — Log Collection

Collects logs from all `ama-logs` agent pods in the `kube-system` namespace:

- **DaemonSet pods** (`ama-logs-*`): `mdsd.err`, `mdsd.qos`, `mdsd.info`, `fluent-bit-out-oms-runtime.log`, `fluent-bit*.log`, container inventory file, process list, full `/etc/mdsd.d/` config directory, agent state directory, and custom prometheus settings
- **ReplicaSet pod** (`ama-logs-rs-*`): same set of runtime logs plus RS-specific configuration and full `/etc/mdsd.d/` config directory
- **Windows DaemonSet pods** (`ama-logs-windows-*`): Windows agent event logs and config
- **Cluster resources**: pod descriptions (`kubectl describe`), ConfigMaps, DCR/DCRA objects, and Kubernetes events for `ama-logs`

### Phase 2 — Network Connectivity

Tests DNS resolution and HTTPS reachability for all required Azure Monitor endpoints:

| Endpoint class | Tested when |
|---|---|
| Global ODS / OMS / agent service | Always |
| Workspace-specific ODS / OMS | `--workspace-id` provided or auto-detected |
| Regional control plane | `--region` provided or auto-detected; **skipped in AMPLS mode** (Azure only creates a private DNS zone for the global handler endpoint, not the regional one) |
| DCE-specific handler endpoint | AMPLS mode only — hostname extracted from `mdsd.info` (`MCS redirected to endpoint` log line) and tested for DNS resolution and HTTPS reachability |

> **AMPLS note:** In AMPLS mode the script always tests the standard `{workspace-id}.ods/oms.opinsights.azure.com` hostnames — not the `.privatelink.` form. The private DNS zones override resolution of the standard hostnames to private IPs, which the DNS test validates. The `.privatelink.` hostnames cause TLS failures because the certificate is issued for `*.ods.opinsights.azure.com`.

### Phase 3 — Log Analysis

Scans the collected logs and reports findings at three severity levels:

| Level | Meaning |
|---|---|
| `[OK]` | Healthy signal confirmed |
| `[INFO]` | Noteworthy but not necessarily an issue (e.g. past errors that resolved, zero-row streams that are expected) |
| `[ISSUE]` | Active problem with remediation guidance |

Files analyzed:

| File | Checks |
|---|---|
| `mdsd.err` | Fatal errors, certificate failures, throttling, config parse errors |
| `mdsd.warn` | Unexpected warnings (benign container-environment systemctl noise is filtered before evaluation) |
| `mdsd.qos` | Data throughput per stream — confirms rows are reaching Azure Monitor |
| `fluent-bit-out-oms-runtime.log` | Continuous output errors (5+ occurrences in recent log) |
| `fluent-bit*.log` | Pipeline errors and back-pressure events |
| `process_*.txt` | Confirms `mdsd`, `td-agent-bit`, and `omsagent` are running |
| `containerID_*.txt` | Validates container inventory is being tracked |
| Pod descriptions | OOMKill events and abnormal restart counts |

### Phase 4 — Azure Configuration Check

When `--cluster-resource-id` is provided, the script uses `az` CLI to check:

- Container Insights add-on status (enabled / disabled)
- Authentication mode (Managed Identity vs. Legacy)
- Data Collection Rule (DCR) and association (DCRA) existence and linkage, including the Data Collection Endpoint (DCE) referenced by the DCR (if any)
- Daily ingestion cap — queries `_LogOperation` for cap-hit events in the last 7 days and lists them if found
- Table-level data activity (last record received per table); if all tables stopped at the same timestamp more than 15 minutes ago, emits an additional warning that the simultaneous cutoff is a strong daily cap indicator
- **AMPLS mode only:** whether the Log Analytics workspace is a connected resource in the AMPLS private link scope
- **AMPLS mode only:** whether a DCE is associated with the cluster (via the DCR or a direct DCRA) and is a connected resource in the AMPLS scope — required for configuration delivery over the private link; also checks `publicNetworkAccess` on the DCE (`Disabled` = config refresh will fail if DCE is not in scope; `Enabled` = currently working over public internet but will break if public access is later disabled)

---

## Output

All files are written to a timestamped directory and then compressed into a `.tar.gz` archive:

```
CILogs_<timestamp>/
├── Tool.log                          # Script execution log
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
│   ├── container_<pod>.conf
│   ├── fluent-bit.conf
│   ├── telegraf.conf
│   └── settings/
├── ama-logs-daemonset-mdsd/          # mdsd logs (err, qos, info, warn)
├── ama-logs-daemonset-dcr/           # DCR configchunks (.json)
├── ama-logs-daemonset-mdsd-config/   # /etc/mdsd.d/ — mdsd.xml and full config
├── ama-logs-prom-daemonset/
│   └── logs_<pod>_prom.txt
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

The final archive is named `CILogs_<timestamp>.tar.gz` in the directory where the script was run.

---

## Required Permissions

### kubectl (read-only)

The script only reads from the cluster — no writes, no deletions.

| Operation | Required |
|---|---|
| `kubectl get nodes/pods` | Yes |
| `kubectl exec` (read-only commands: `ps`, `ls`, `cat`) | Yes |
| `kubectl describe pod` | Yes |
| `kubectl get configmap / dcr / dcra` | Yes |

### Azure CLI (optional, for `--cluster-resource-id` checks)

| Scope | Required role |
|---|---|
| AKS cluster resource | `Reader` |
| Log Analytics workspace | `Log Analytics Reader` |
| AMPLS scope (if `--ampls` or auto-detected) | `Reader` on the private link scope resource |
| Data Collection Endpoint (if DCE is configured) | `Reader` |

---

## Contributing

Contributions are welcome. Please open an issue or pull request for bug reports, new check ideas, or additional endpoint coverage.
