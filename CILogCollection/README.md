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

- **DaemonSet pods** (`ama-logs-*`): `mdsd.err`, `mdsd.qos`, `mdsd.info`, `fluent-bit-out-oms-runtime.log`, `fluent-bit*.log`, container inventory file, and process list
- **ReplicaSet pod** (`ama-logs-rs-*`): same set of runtime logs plus RS-specific configuration
- **Windows DaemonSet pods** (`ama-logs-windows-*`): Windows agent event logs and config
- **Cluster resources**: pod descriptions (`kubectl describe`), ConfigMaps, DCR/DCRA objects, and Kubernetes events for `ama-logs`

### Phase 2 — Network Connectivity

Tests DNS resolution and HTTPS reachability for all required Azure Monitor endpoints:

| Endpoint class | Tested when |
|---|---|
| Global ODS / OMS / agent service | Always |
| Workspace-specific ODS / OMS | `--workspace-id` provided or auto-detected |
| Regional control plane | `--region` provided or auto-detected |
| Private link (AMPLS) overrides | AMPLS detected or `--ampls` passed |

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
- Data Collection Rule (DCR) and association (DCRA) existence and linkage
- Daily ingestion cap — alerts if within 20% of the cap or if cap is hit
- Table-level data activity (last record received per table)

---

## Output

All files are written to a timestamped directory and then compressed into a `.tar.gz` archive:

```
CILogs_<timestamp>/
├── Tool.log                          # Script execution log
├── analysis_log.txt                  # Full analysis findings
├── nodes.txt                         # kubectl get nodes output
├── pods.txt                          # kubectl get pods -n kube-system output
├── ama-logs-daemonset-<pod>/
│   ├── mdsd.err
│   ├── mdsd.qos
│   ├── mdsd.info
│   ├── fluent-bit-out-oms-runtime.log
│   ├── fluent-bit*.log
│   ├── containerID_<pod>.txt
│   └── process_<pod>.txt
├── ama-logs-replicaset-<pod>/
│   └── (same structure)
├── ama-logs-windows-<pod>/
│   └── (Windows-specific logs)
├── describe_<pod>.txt                # kubectl describe output per pod
├── configmaps.txt
├── dcr.txt / dcra.txt
└── events_ama_logs.txt
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

---

## Contributing

Contributions are welcome. Please open an issue or pull request for bug reports, new check ideas, or additional endpoint coverage.
