#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Description: Collects logs from Container Insights agent pods (ama-logs),
#              tests network connectivity to Azure Monitor endpoints, and
#              analyzes collected logs for common known issues.
# Author: Brandon DeGolier

# ─── Colors ──────────────────────────────────────────────────────────────────
Red='\033[0;31m'
Yellow='\033[1;33m'
Green='\033[0;32m'
Cyan='\033[0;36m'
Bold='\033[1m'
NC='\033[0m'

# ─── Globals ─────────────────────────────────────────────────────────────────
WORKSPACE_ID=""
CLUSTER_REGION=""
CLUSTER_RESOURCE_ID=""
USE_AMPLS=false
DETECTED_DCE_ID=""
DETECTED_DCR_CLV2=""
DETECTED_MSI_CLIENT_ID=""
DETECTED_MSI_OBJECT_ID=""
DETECTED_MSI_RESOURCE_ID=""
SKIP_NETWORK=false
SKIP_ANALYSIS=false
ANALYSIS_FINDINGS=()

# ─── parse_args ───────────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --workspace-id) WORKSPACE_ID="$2";        shift 2 ;;
            --region)       CLUSTER_REGION="$2";      shift 2 ;;
            --cluster-resource-id) CLUSTER_RESOURCE_ID="$2"; shift 2 ;;
            --ampls)        USE_AMPLS=true;            shift   ;;
            --skip-network) SKIP_NETWORK=true;         shift   ;;
            --skip-analysis)SKIP_ANALYSIS=true;        shift   ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo ""
                echo "  --workspace-id <guid>          Log Analytics Workspace ID (short GUID, found on workspace Overview"
                echo "                                 page in the Azure Portal). Enables workspace endpoint tests and"
                echo "                                 daily cap checks."
                echo "  --region <region>              Azure region of the cluster (e.g. eastus, westus2). Enables"
                echo "                                 regional control plane endpoint tests."
                echo "  --cluster-resource-id <id>     Full AKS resource ID. Enables Azure configuration checks:"
                echo "                                 authentication mode, Data Collection Rule (DCR) validation,"
                echo "                                 and daily ingestion cap query."
                echo "  --ampls                        Force Azure Monitor Private Link Scope (AMPLS) mode."
                echo "                                 Use when your cluster sends data through private endpoints"
                echo "                                 instead of public Azure Monitor endpoints. AMPLS is usually"
                echo "                                 auto-detected, but this flag overrides if detection fails."
                echo "  --skip-network                 Skip network connectivity tests (DNS + HTTPS checks)"
                echo "  --skip-analysis                Skip post-collection log analysis"
                echo ""
                echo "Examples:"
                echo "  $0 --workspace-id a1b2c3d4-... --region eastus"
                echo "  $0 --cluster-resource-id /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ContainerService/managedClusters/<name>"
                echo "  $0 --ampls --skip-network"
                exit 0 ;;
            *) echo -e "${Red}Unknown argument: $1. Run $0 --help for usage.${NC}"; exit 1 ;;
        esac
    done
}

# ─── init ─────────────────────────────────────────────────────────────────────
init() {
    echo -e "Preparing for log collection..." | tee -a Tool.log

    if ! cmd="$(type -p kubectl)" || [[ -z $cmd ]]; then
        echo -e "${Red}[ERROR] kubectl not found." | tee -a Tool.log
        echo -e "        Install kubectl and connect to your cluster first:" | tee -a Tool.log
        echo -e "        az aks get-credentials --resource-group <RG> --name <CLUSTER>${NC}" | tee -a Tool.log
        cd ..; rm -rf "$output_path"; exit 1
    fi

    if ! cmd="$(type -p tar)" || [[ -z $cmd ]]; then
        echo -e "${Red}[ERROR] tar not found. Install tar before retrying.${NC}" | tee -a Tool.log
        cd ..; rm -rf "$output_path"; exit 1
    fi

    local node_check node_exit
    node_check=$(kubectl get nodes 2>&1)
    node_exit=$?
    if [[ $node_exit -ne 0 ]]; then
        echo -e "${Red}[ERROR] Cannot connect to the cluster (kubectl exited with code ${node_exit}).${NC}" | tee -a Tool.log
        echo -e "${Red}        kubectl output:${NC}" | tee -a Tool.log
        echo "$node_check" | sed 's/^/          /' | tee -a Tool.log
        echo -e "${Red}        Verify your kubeconfig is set and the API server is reachable:" | tee -a Tool.log
        echo -e "          kubectl config current-context" | tee -a Tool.log
        echo -e "          az aks get-credentials --resource-group <RG> --name <CLUSTER>${NC}" | tee -a Tool.log
        cd ..; rm -rf "$output_path"; exit 1
    fi

    local not_ready=false
    while IFS= read -r node_status; do
        if [[ $(echo "$node_status" | tr '[:upper:]' '[:lower:]') != "ready" ]]; then
            not_ready=true
        fi
    done < <(kubectl get nodes 2>/dev/null | tail -n +2 | awk '{print $2}')

    if $not_ready; then
        kubectl get nodes | tee -a Tool.log
        echo -e "${Yellow}[WARN] One or more nodes are not Ready. Log collection will continue but logs from" | tee -a Tool.log
        echo -e "       not-ready nodes may be incomplete or missing.${NC}" | tee -a Tool.log
    fi

    echo -e "${Green}[OK] Prerequisites verified: kubectl connected, tar available, cluster reachable.${NC}" | tee -a Tool.log
    echo -e "Saving cluster information..." | tee -a Tool.log

    local cluster_info
    cluster_info=$(kubectl cluster-info 2>&1)
    if [[ $cluster_info == *"refused"* ]]; then
        echo -e "${Red}[ERROR] Failed to retrieve cluster info. Check cluster connectivity.${NC}" | tee -a Tool.log
    else
        echo "$cluster_info" >> Tool.log
        echo -e "Cluster info saved to Tool.log" | tee -a Tool.log
    fi
}

# ─── derive_cluster_info ──────────────────────────────────────────────────────
# Auto-detects workspace ID and cluster region if not provided as arguments.
# Region is read from standard AKS node topology labels (very reliable).
# Workspace ID is attempted from pod environment then configmap data.
derive_cluster_info() {
    if [[ -z "$CLUSTER_REGION" ]]; then
        CLUSTER_REGION=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}' 2>/dev/null)
        if [[ -n "$CLUSTER_REGION" ]]; then
            echo -e "Auto-detected cluster region: ${Cyan}${CLUSTER_REGION}${NC}" | tee -a Tool.log
        else
            echo -e "${Yellow}[WARN] Could not auto-detect cluster region." | tee -a Tool.log
            echo -e "       Region-specific endpoint tests will be skipped." | tee -a Tool.log
            echo -e "       Pass --region <region> to enable them (e.g. --region eastus).${NC}" | tee -a Tool.log
        fi
    fi

    if [[ -z "$WORKSPACE_ID" ]]; then
        # Attempt 1: environment variable inside the DS pod
        if [[ -n "$ds_pod" ]]; then
            WORKSPACE_ID=$(kubectl exec "${ds_pod}" -n kube-system -c ama-logs -- env 2>/dev/null \
                | grep -iE "^WSID=|^WORKSPACE_ID=" | head -1 | cut -d= -f2)
        fi

        # Attempt 2: cluster configmap
        if [[ -z "$WORKSPACE_ID" ]]; then
            local cm_data
            cm_data=$(kubectl get configmap container-azm-ms-aks-k8scluster -n kube-system \
                -o jsonpath='{.data}' 2>/dev/null)
            if [[ -n "$cm_data" ]]; then
                WORKSPACE_ID=$(echo "$cm_data" | grep -oP '"WorkspaceId"\s*:\s*"\K[^"]+' 2>/dev/null | head -1)
            fi
        fi

        # Attempt 3: parse already-collected configchunks for ODS endpoint pattern
        if [[ -z "$WORKSPACE_ID" ]] && [[ -d "ama-logs-daemonset-dcr" ]]; then
            WORKSPACE_ID=$(grep -roh '[a-z0-9]\{8\}-[a-z0-9]\{4\}-[a-z0-9]\{4\}-[a-z0-9]\{4\}-[a-z0-9]\{12\}\.ods\.opinsights' \
                ama-logs-daemonset-dcr/ 2>/dev/null | head -1 | sed 's/\.ods\.opinsights//')
        fi

        if [[ -n "$WORKSPACE_ID" ]]; then
            echo -e "Auto-detected Workspace ID: ${Cyan}${WORKSPACE_ID}${NC}" | tee -a Tool.log
        else
            echo -e "${Yellow}[WARN] Could not auto-detect Log Analytics Workspace ID." | tee -a Tool.log
            echo -e "       Workspace-specific endpoint tests will be skipped." | tee -a Tool.log
            echo -e "       Pass --workspace-id <guid> to enable them (found on workspace Overview page).${NC}" | tee -a Tool.log
        fi
    fi

    # Auto-detect CLUSTER_RESOURCE_ID via IMDS from inside the DS pod. ama-logs DS runs with
    # hostNetwork=true so 169.254.169.254 is reachable. AKS-managed VMSS instances carry
    # 'aks-managed-cluster-name' and 'aks-managed-cluster-rg' tags that, combined with the
    # subscription ID from IMDS compute metadata, give the full cluster resource ID — enabling
    # azure_config_check to run by default.
    if [[ -z "$CLUSTER_RESOURCE_ID" ]] && [[ -n "$ds_pod" ]] && type -p python3 > /dev/null 2>&1; then
        local imds_compute
        imds_compute=$(kubectl exec "${ds_pod}" -n kube-system -c ama-logs -- \
            curl -s --connect-timeout 5 --max-time 10 -H "Metadata:true" \
            "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01" 2>/dev/null)

        if [[ -n "$imds_compute" ]] && echo "$imds_compute" | grep -q '"subscriptionId"'; then
            local derived_id
            derived_id=$(echo "$imds_compute" | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    sub = d.get('subscriptionId','')
    tags = {t.get('name'): t.get('value') for t in d.get('tagsList',[]) if t.get('name')}
    cn = tags.get('aks-managed-cluster-name','')
    cr = tags.get('aks-managed-cluster-rg','')
    if not (cn and cr):
        mc = d.get('resourceGroupName','')
        m = re.match(r'^MC_(.+)_([^_]+)_[^_]+$', mc)
        if m:
            cr, cn = m.group(1), m.group(2)
    if sub and cn and cr:
        print(f'/subscriptions/{sub}/resourceGroups/{cr}/providers/Microsoft.ContainerService/managedClusters/{cn}')
except Exception:
    pass
" 2>/dev/null)
            if [[ -n "$derived_id" ]]; then
                CLUSTER_RESOURCE_ID="$derived_id"
                echo -e "Auto-detected cluster resource ID via IMDS: ${Cyan}${CLUSTER_RESOURCE_ID}${NC}" | tee -a Tool.log
            else
                echo -e "${Yellow}[WARN] IMDS reachable but could not derive the cluster resource ID from tags or MC_ name." | tee -a Tool.log
                echo -e "       Pass --cluster-resource-id to enable Azure configuration checks.${NC}" | tee -a Tool.log
            fi
        else
            echo -e "${Cyan}[INFO] IMDS (169.254.169.254) was not reachable from the agent pod — cluster resource ID auto-detection skipped." | tee -a Tool.log
            echo -e "       Pass --cluster-resource-id to enable Azure configuration checks.${NC}" | tee -a Tool.log
        fi
    fi

    # Auto-detect AMPLS: if the ODS endpoint resolves to a private RFC1918 address, the cluster
    # is behind a private link scope. Skip if --ampls was already passed explicitly.
    if ! $USE_AMPLS && [[ -n "$WORKSPACE_ID" ]]; then
        local test_pod="${ds_pod:-$rs_pod}"
        if [[ -n "$test_pod" ]]; then
            local ods_host="${WORKSPACE_ID}.ods.opinsights.azure.com"
            local resolved_ip
            resolved_ip=$(kubectl exec "${test_pod}" -n kube-system -c ama-logs -- \
                nslookup "$ods_host" 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}')

            if [[ -n "$resolved_ip" ]] && \
               echo "$resolved_ip" | grep -qE "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)"; then
                USE_AMPLS=true
                echo -e "${Cyan}[INFO] AMPLS auto-detected: ${ods_host} resolved to private IP (${resolved_ip})." | tee -a Tool.log
                echo -e "       ODS/OMS endpoints will resolve to private IPs via DNS override.${NC}" | tee -a Tool.log
            fi
        fi
    fi
}

# ─── _classify_previous_logs ──────────────────────────────────────────────────
# Inspect `kubectl describe pod` output to decide whether a previous restart
# was graceful (config reload, rollout restart, node drain) or a real crash.
# Sets four caller-scoped variables (caller MUST declare them `local` first
# AND NOT call this via command substitution — that would run in a subshell
# and the assignments wouldn't survive):
#   last_class  — "graceful" or "crash"
#   last_reason — Last State Reason   (e.g. Completed, Error, OOMKilled)
#   last_exit   — Last State ExitCode (0 / 143 = graceful, 137 = OOM, etc.)
#   last_msg    — Last State Message  (sometimes empty)
# Three graceful signals — any one is enough:
#   - Reason = Completed
#   - Exit Code = 0 or 143 (SIGTERM = 128+15, sent by kubelet on a probe-driven
#     kill or graceful pod termination)
#   - Message contains a config-change marker — the agent's own way of saying
#     "I shut myself down to pick up new config"
_classify_previous_logs() {
    local desc="$1"
    last_reason=$(awk '
        /^[[:space:]]*Last State:[[:space:]]*Terminated/ { capture=1; next }
        capture && /^[[:space:]]*Reason:/                { print $2; exit }
    ' "$desc" 2>/dev/null)
    last_exit=$(awk '
        /^[[:space:]]*Last State:[[:space:]]*Terminated/ { capture=1; next }
        capture && /^[[:space:]]*Exit Code:/             { print $3; exit }
    ' "$desc" 2>/dev/null)
    last_msg=$(awk '
        /^[[:space:]]*Last State:[[:space:]]*Terminated/ { capture=1; next }
        capture && /^[[:space:]]*Message:/ { sub(/^[[:space:]]*Message:[[:space:]]*/, ""); print; exit }
    ' "$desc" 2>/dev/null)
    if [[ "$last_reason" == "Completed" || "$last_exit" == "0" || "$last_exit" == "143" ]]; then
        last_class=graceful; return
    fi
    if echo "$last_msg" | grep -qiE "config[[:space:]]*changed|inotifyoutput|config[[:space:]]*map[[:space:]]*updated"; then
        last_class=graceful; return
    fi
    last_class=crash
}

# ─── ds_logCollection ─────────────────────────────────────────────────────────
ds_logCollection() {
    echo -e "\nCollecting logs from DaemonSet pod: ${ds_pod}..." | tee -a Tool.log
    mkdir -p ama-logs-daemonset ama-logs-prom-daemonset
    kubectl describe pod "${ds_pod}" --namespace=kube-system > "ama-logs-daemonset/describe_${ds_pod}.txt" 2>&1
    kubectl logs "${ds_pod}" --container ama-logs --namespace=kube-system > "ama-logs-daemonset/logs_${ds_pod}.txt" 2>&1
    kubectl logs "${ds_pod}" --container ama-logs-prometheus --namespace=kube-system > "ama-logs-prom-daemonset/logs_${ds_pod}_prom.txt" 2>/dev/null
    if kubectl logs "${ds_pod}" --container ama-logs --namespace=kube-system --previous > "ama-logs-daemonset/logs_${ds_pod}_previous.txt" 2>/dev/null; then
        local last_class last_reason last_exit last_msg
        _classify_previous_logs "ama-logs-daemonset/describe_${ds_pod}.txt"
        if [[ "$last_class" == "graceful" ]]; then
            echo -e "  ${Cyan}[INFO] Previous (pre-restart) logs collected for ${ds_pod} — restart appears graceful (Reason=${last_reason:-?}, ExitCode=${last_exit:-?}).${NC}" | tee -a Tool.log
            [[ -n "$last_msg" ]] && echo -e "         Last State Message: ${last_msg}" | tee -a Tool.log
            echo -e "         Typically a ConfigMap update, 'kubectl rollout restart', or a node drain — not a crash. Previous logs are still saved for context." | tee -a Tool.log
        else
            echo -e "  ${Yellow}[WARN] Previous (pre-restart) logs collected for ${ds_pod} - this pod has restarted at least once.${NC}" | tee -a Tool.log
            echo -e "         Last termination: Reason=${last_reason:-unknown}, ExitCode=${last_exit:-unknown} — looks like a crash." | tee -a Tool.log
            [[ -n "$last_msg" ]] && echo -e "         Last State Message: ${last_msg}" | tee -a Tool.log
            echo -e "         Review ama-logs-daemonset/logs_${ds_pod}_previous.txt to see what caused the restart.${NC}" | tee -a Tool.log
        fi
    fi
    kubectl exec "${ds_pod}" -n kube-system -c ama-logs --request-timeout=10m -- ps -ef > "ama-logs-daemonset/process_${ds_pod}.txt" 2>/dev/null

    local check
    check=$(kubectl exec "${ds_pod}" -n kube-system -c ama-logs -- ls /var/opt/microsoft 2>&1)
    if [[ $check == *"cannot access"* ]] || [[ $check == *"No such file"* ]]; then
        echo -e "${Red}[ERROR] /var/opt/microsoft not found on ${ds_pod}." | tee -a Tool.log
        echo -e "        The agent may not have initialized correctly." | tee -a Tool.log
        echo -e "        Check: kubectl describe pod ${ds_pod} -n kube-system for init container errors.${NC}" | tee -a Tool.log
        ANALYSIS_FINDINGS+=("CRITICAL: /var/opt/microsoft missing on DS pod ${ds_pod}. Agent likely did not initialize. Check init container status via kubectl describe.")
    else
        echo -e "  Collecting from ${ds_pod}:"
        echo -e "    /var/opt/microsoft/docker-cimprov/log"
        echo -e "      fluent-bit logs  : container log collector - reads /var/log/containers/ on each node"
        echo -e "      fluentd logs     : routes collected data to the monitoring pipeline"
        echo -e "      OMS runtime logs : output plugin that sends data to Azure Monitor"
        echo -e "    /var/opt/microsoft/linuxmonagent/log"
        echo -e "      mdsd (Monitoring Data Sink Daemon) - the agent's core engine that processes and forwards data"
        echo -e "      mdsd.err: errors | mdsd.info: operational events | mdsd.qos: per-table throughput metrics"
        echo -e "    /etc/mdsd.d/config-cache/configchunks/"
        echo -e "      DCR config files - the Data Collection Rule instructions delivered from Azure telling the"
        echo -e "      agent what data to collect, which tables to write to, and at what interval"
        kubectl cp "${ds_pod}:/var/opt/microsoft/docker-cimprov/log"    ama-logs-daemonset          --namespace=kube-system --container ama-logs > /dev/null 2>&1
        kubectl cp "${ds_pod}:/var/opt/microsoft/docker-cimprov/log"    ama-logs-prom-daemonset     --namespace=kube-system --container ama-logs-prometheus > /dev/null 2>&1
        kubectl cp "${ds_pod}:/var/opt/microsoft/linuxmonagent/log"     ama-logs-daemonset-mdsd     --namespace=kube-system --container ama-logs > /dev/null 2>&1
        kubectl cp "${ds_pod}:/var/opt/microsoft/linuxmonagent/log"     ama-logs-prom-daemonset-mdsd --namespace=kube-system --container ama-logs-prometheus > /dev/null 2>&1
        kubectl cp "${ds_pod}:/etc/mdsd.d/config-cache/configchunks/"  ama-logs-daemonset-dcr      --namespace=kube-system --container ama-logs > /dev/null 2>&1
        echo -e "    /etc/mdsd.d/"
        echo -e "      mdsd config directory - mdsd.xml defines sources, sinks, and the output pipeline"
        kubectl cp "${ds_pod}:/etc/mdsd.d/" ama-logs-daemonset-mdsd-config --namespace=kube-system --container ama-logs > /dev/null 2>&1

        # A missing or empty configchunks dir means the agent has not received its DCR config.
        local chunk_count
        chunk_count=$(kubectl exec "${ds_pod}" -n kube-system -c ama-logs \
            -- sh -c 'ls /etc/mdsd.d/config-cache/configchunks/ 2>/dev/null | grep -c "\.json$"' 2>/dev/null \
            | tr -d '[:space:]')
        [[ "$chunk_count" =~ ^[0-9]+$ ]] || chunk_count=0
        if [[ "$chunk_count" -eq 0 ]]; then
            echo -e "${Red}[ISSUE] DCR configuration files (configchunks) are missing on ${ds_pod}." | tee -a Tool.log
            echo -e "        The agent has NOT received its Data Collection Rule (DCR) — the instructions from" | tee -a Tool.log
            echo -e "        Azure that tell it what to collect. Without this, no data will be collected at all." | tee -a Tool.log
            echo -e "        Most likely cause: the agent cannot reach the Azure Monitor control plane endpoints." | tee -a Tool.log
            echo -e "        Check firewall/NSG rules allow outbound HTTPS (port 443) to:${NC}" | tee -a Tool.log
            echo -e "          global.handler.control.monitor.azure.com" | tee -a Tool.log
            echo -e "          <region>.handler.control.monitor.azure.com" | tee -a Tool.log
            ANALYSIS_FINDINGS+=("CRITICAL: DCR configchunks empty on DS pod ${ds_pod}. Agent has not received DCR config. Verify DCR/DCRA is associated and check firewall rules for global.handler.control.monitor.azure.com and <region>.handler.control.monitor.azure.com:443.")
        else
            echo -e "  ${Green}[OK] DCR configuration files present (${chunk_count} file(s)) - agent has received and loaded its Data Collection Rule.${NC}"
        fi
    fi

    kubectl exec "${ds_pod}" --namespace=kube-system -c ama-logs -- \
        ls /var/opt/microsoft/docker-cimprov/state/ContainerInventory > "ama-logs-daemonset/containerID_${ds_pod}.txt" 2>&1

    check=$(kubectl exec "${ds_pod}" -n kube-system -c ama-logs -- ls /etc/fluent 2>&1)
    if [[ $check != *"cannot access"* ]] && [[ $check != *"No such file"* ]]; then
        echo -e "    /etc/fluent/container.conf"
        kubectl cp "${ds_pod}:/etc/fluent/container.conf" "ama-logs-daemonset/container_${ds_pod}.conf"      --namespace=kube-system --container ama-logs > /dev/null 2>&1
        kubectl cp "${ds_pod}:/etc/fluent/container.conf" "ama-logs-prom-daemonset/container_${ds_pod}.conf" --namespace=kube-system --container ama-logs-prometheus > /dev/null 2>&1
    fi

    check=$(kubectl exec "${ds_pod}" -n kube-system -c ama-logs -- ls /etc/opt/microsoft/docker-cimprov 2>&1)
    if [[ $check != *"cannot access"* ]] && [[ $check != *"No such file"* ]]; then
        echo -e "    /etc/opt/microsoft/docker-cimprov/fluent-bit.conf"
        echo -e "    /etc/opt/microsoft/docker-cimprov/telegraf.conf"
        kubectl cp "${ds_pod}:/etc/opt/microsoft/docker-cimprov/fluent-bit.conf" ama-logs-daemonset/fluent-bit.conf      --namespace=kube-system --container ama-logs > /dev/null 2>&1
        kubectl cp "${ds_pod}:/etc/opt/microsoft/docker-cimprov/telegraf.conf"   ama-logs-daemonset/telegraf.conf         --namespace=kube-system --container ama-logs > /dev/null 2>&1
        kubectl cp "${ds_pod}:/etc/opt/microsoft/docker-cimprov/fluent-bit.conf" ama-logs-prom-daemonset/fluent-bit.conf  --namespace=kube-system --container ama-logs-prometheus > /dev/null 2>&1
        kubectl cp "${ds_pod}:/etc/opt/microsoft/docker-cimprov/telegraf.conf"   ama-logs-prom-daemonset/telegraf.conf    --namespace=kube-system --container ama-logs-prometheus > /dev/null 2>&1
    fi

    check=$(kubectl exec "${ds_pod}" -n kube-system -c ama-logs -- ls /etc/config/settings 2>&1)
    if [[ $check != *"cannot access"* ]] && [[ $check != *"No such file"* ]]; then
        echo -e "    /etc/config/settings"
        echo -e "      custom prometheus/metrics settings applied from ConfigMap"
        kubectl cp "${ds_pod}:/etc/config/settings/" ama-logs-daemonset/settings --namespace=kube-system --container ama-logs > /dev/null 2>&1
    fi

    echo -e "Complete log collection from ${ds_pod}!" | tee -a Tool.log
}

# ─── win_logCollection ────────────────────────────────────────────────────────
win_logCollection() {
    echo -e "\nCollecting logs from Windows pod: ${ds_win_pod} (this may take several minutes)..." | tee -a Tool.log
    mkdir -p ama-logs-windows-daemonset
    kubectl describe pod "${ds_win_pod}" --namespace=kube-system > "ama-logs-windows-daemonset/describe_${ds_win_pod}.txt" 2>&1
    kubectl logs "${ds_win_pod}" --container ama-logs-windows --namespace=kube-system > "ama-logs-windows-daemonset/logs_${ds_win_pod}.txt" 2>&1
    kubectl exec "${ds_win_pod}" -n kube-system --request-timeout=10m -- powershell Get-Process > "ama-logs-windows-daemonset/process_${ds_win_pod}.txt" 2>/dev/null

    local check
    check=$(kubectl exec "${ds_win_pod}" -n kube-system -- powershell ls /etc 2>&1)
    if [[ $check == *"cannot access"* ]] || [[ $check == *"No such file"* ]]; then
        echo -e "${Red}[ERROR] /etc/ not found on Windows pod ${ds_win_pod}.${NC}" | tee -a Tool.log
        return
    fi

    echo -e "${Cyan}[INFO] If Windows log collection fails due to log size, delete and recreate the pod" | tee -a Tool.log
    echo -e "       to rotate logs before retrying: kubectl delete pod ${ds_win_pod} -n kube-system${NC}" | tee -a Tool.log

    kubectl cp "${ds_win_pod}:/etc/fluent-bit" ama-logs-windows-daemonset-fbit --namespace=kube-system > /dev/null 2>&1
    kubectl cp "${ds_win_pod}:/etc/telegraf/telegraf.conf" ama-logs-windows-daemonset-fbit/telegraf.conf --namespace=kube-system > /dev/null 2>&1

    local win_logs=(
        kubernetes_perf_log.txt
        appinsights_error.log
        filter_cadvisor2mdm.log
        fluent-bit-out-oms-runtime.log
        kubernetes_client_log.txt
        mdm_metrics_generator.log
        out_oms.conf
    )
    for logfile in "${win_logs[@]}"; do
        kubectl exec "${ds_win_pod}" -n kube-system --request-timeout=10m -- \
            powershell cat "/etc/amalogswindows/${logfile}" > "ama-logs-windows-daemonset/${logfile}" 2>/dev/null
    done

    echo -e "Complete log collection from ${ds_win_pod}!" | tee -a Tool.log
}

# ─── rs_logCollection ─────────────────────────────────────────────────────────
rs_logCollection() {
    echo -e "\nCollecting logs from ReplicaSet pod: ${rs_pod}..." | tee -a Tool.log
    mkdir -p ama-logs-replicaset
    kubectl describe pod "${rs_pod}" --namespace=kube-system > "ama-logs-replicaset/describe_${rs_pod}.txt" 2>&1
    kubectl logs "${rs_pod}" --container ama-logs --namespace=kube-system > "ama-logs-replicaset/logs_${rs_pod}.txt" 2>&1
    if kubectl logs "${rs_pod}" --container ama-logs --namespace=kube-system --previous > "ama-logs-replicaset/logs_${rs_pod}_previous.txt" 2>/dev/null; then
        local last_class last_reason last_exit last_msg
        _classify_previous_logs "ama-logs-replicaset/describe_${rs_pod}.txt"
        if [[ "$last_class" == "graceful" ]]; then
            echo -e "  ${Cyan}[INFO] Previous (pre-restart) logs collected for ${rs_pod} — restart appears graceful (Reason=${last_reason:-?}, ExitCode=${last_exit:-?}).${NC}" | tee -a Tool.log
            [[ -n "$last_msg" ]] && echo -e "         Last State Message: ${last_msg}" | tee -a Tool.log
            echo -e "         Typically a ConfigMap update, 'kubectl rollout restart', or a node drain — not a crash. Previous logs are still saved for context." | tee -a Tool.log
        else
            echo -e "  ${Yellow}[WARN] Previous (pre-restart) logs collected for ${rs_pod} - this pod has restarted at least once.${NC}" | tee -a Tool.log
            echo -e "         Last termination: Reason=${last_reason:-unknown}, ExitCode=${last_exit:-unknown} — looks like a crash." | tee -a Tool.log
            [[ -n "$last_msg" ]] && echo -e "         Last State Message: ${last_msg}" | tee -a Tool.log
            echo -e "         Review ama-logs-replicaset/logs_${rs_pod}_previous.txt to see what caused the restart.${NC}" | tee -a Tool.log
        fi
    fi
    kubectl exec "${rs_pod}" -n kube-system -c ama-logs --request-timeout=10m -- ps -ef > "ama-logs-replicaset/process_${rs_pod}.txt" 2>/dev/null

    local check
    check=$(kubectl exec "${rs_pod}" -n kube-system -c ama-logs -- ls /var/opt/microsoft 2>&1)
    if [[ $check == *"cannot access"* ]] || [[ $check == *"No such file"* ]]; then
        echo -e "${Red}[ERROR] /var/opt/microsoft not found on ${rs_pod}." | tee -a Tool.log
        echo -e "        The RS agent may not have initialized correctly.${NC}" | tee -a Tool.log
        ANALYSIS_FINDINGS+=("CRITICAL: /var/opt/microsoft missing on RS pod ${rs_pod}. Agent likely did not initialize.")
    else
        echo -e "  Collecting from ${rs_pod}:"
        echo -e "    /var/opt/microsoft/docker-cimprov/log"
        echo -e "      fluentd logs : collects cluster-level data (Kubernetes events, pod inventory, node inventory)"
        echo -e "    /var/opt/microsoft/linuxmonagent/log"
        echo -e "      mdsd (Monitoring Data Sink Daemon) - processes and forwards cluster-level metrics and logs"
        echo -e "    /etc/mdsd.d/config-cache/configchunks/"
        echo -e "      DCR config files - Data Collection Rule instructions delivered from Azure"
        kubectl cp "${rs_pod}:/var/opt/microsoft/docker-cimprov/log"   ama-logs-replicaset      --namespace=kube-system > /dev/null 2>&1
        kubectl cp "${rs_pod}:/var/opt/microsoft/linuxmonagent/log"    ama-logs-replicaset-mdsd --namespace=kube-system > /dev/null 2>&1
        kubectl cp "${rs_pod}:/etc/mdsd.d/config-cache/configchunks/" ama-logs-replicaset-dcr  --namespace=kube-system --container ama-logs > /dev/null 2>&1
        echo -e "    /etc/mdsd.d/"
        kubectl cp "${rs_pod}:/etc/mdsd.d/" ama-logs-replicaset-mdsd-config --namespace=kube-system --container ama-logs > /dev/null 2>&1

        local chunk_count
        chunk_count=$(kubectl exec "${rs_pod}" -n kube-system -c ama-logs \
            -- sh -c 'ls /etc/mdsd.d/config-cache/configchunks/ 2>/dev/null | grep -c "\.json$"' 2>/dev/null \
            | tr -d '[:space:]')
        [[ "$chunk_count" =~ ^[0-9]+$ ]] || chunk_count=0
        if [[ "$chunk_count" -eq 0 ]]; then
            echo -e "${Red}[ISSUE] DCR configchunks directory is empty on RS pod ${rs_pod}.${NC}" | tee -a Tool.log
            ANALYSIS_FINDINGS+=("CRITICAL: DCR configchunks empty on RS pod ${rs_pod}. Agent has not received DCR config.")
        else
            echo -e "  ${Green}[OK] DCR configuration files present on RS pod (${chunk_count} file(s)) - agent has received its Data Collection Rule.${NC}"
        fi
    fi

    check=$(kubectl exec "${rs_pod}" -n kube-system -c ama-logs -- ls /etc/fluent 2>&1)
    if [[ $check != *"cannot access"* ]] && [[ $check != *"No such file"* ]]; then
        echo -e "    /etc/fluent/kube.conf"
        kubectl cp "${rs_pod}:/etc/fluent/kube.conf" "ama-logs-replicaset/kube_${rs_pod}.conf" \
            --namespace=kube-system --container ama-logs > /dev/null 2>&1
    fi

    check=$(kubectl exec "${rs_pod}" -n kube-system -c ama-logs -- ls /etc/opt/microsoft/docker-cimprov 2>&1)
    if [[ $check != *"cannot access"* ]] && [[ $check != *"No such file"* ]]; then
        echo -e "    /etc/opt/microsoft/docker-cimprov/fluent-bit-rs.conf"
        echo -e "    /etc/opt/microsoft/docker-cimprov/telegraf-rs.conf"
        kubectl cp "${rs_pod}:/etc/opt/microsoft/docker-cimprov/fluent-bit-rs.conf" ama-logs-replicaset/fluent-bit-rs.conf \
            --namespace=kube-system --container ama-logs > /dev/null 2>&1
        kubectl cp "${rs_pod}:/etc/opt/microsoft/docker-cimprov/telegraf-rs.conf"   ama-logs-replicaset/telegraf-rs.conf   \
            --namespace=kube-system --container ama-logs > /dev/null 2>&1
    fi

    echo -e "Complete log collection from ${rs_pod}!" | tee -a Tool.log
}

# ─── other_logCollection ──────────────────────────────────────────────────────
other_logCollection() {
    echo -e "\nCollecting cluster metadata..." | tee -a Tool.log
    mkdir -p cluster

    local deploy
    deploy=$(kubectl get deployment --namespace=kube-system | grep -E ama-logs | head -n 1 | awk '{print $1}')
    if [[ -z "$deploy" ]]; then
        echo -e "${Red}[ERROR] No ama-logs deployment found in kube-system." | tee -a Tool.log
        echo -e "        Container Insights addon may not be enabled on this cluster.${NC}" | tee -a Tool.log
        ANALYSIS_FINDINGS+=("No ama-logs deployment found. Container Insights addon may not be enabled or may have been removed from the cluster.")
    else
        echo -e "  Collecting deployment info for: ${deploy}"
        kubectl get deployment "$deploy" --namespace=kube-system -o yaml > "cluster/deployment_${deploy}.yaml"
    fi

    # All relevant ConfigMaps - missing ones are informational only (cluster may use defaults)
    local -A cms=(
        ["container-azm-ms-agentconfig"]="Agent config (custom ConfigMap)"
        ["container-azm-ms-aks-k8scluster"]="Cluster identity/workspace config"
        ["ama-logs-rs-config"]="ReplicaSet agent config"
    )
    for pattern in "${!cms[@]}"; do
        local cm_name
        cm_name=$(kubectl get configmaps --namespace=kube-system | grep -E "$pattern" | head -n 1 | awk '{print $1}')
        if [[ -z "$cm_name" ]]; then
            echo -e "  ${Cyan}[INFO] ConfigMap '${pattern}' not found - cluster likely using defaults.${NC}"
        else
            echo -e "  Collecting configmap: ${cm_name} (${cms[$pattern]})"
            kubectl get configmaps "$cm_name" --namespace=kube-system -o yaml > "cluster/${cm_name}.yaml"
        fi
    done

    # Node info + quick status snapshots for the archive
    kubectl get nodes > cluster/node.txt 2>&1
    kubectl get nodes -o json > cluster/node-detailed.json 2>&1
    kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.status=="True")]}{.type}{","}{end}{"\n"}{end}' > cluster/node-conditions.txt 2>&1
    kubectl get daemonset -n kube-system | grep ama-logs > cluster/daemonset-status.txt 2>&1
    kubectl get pods -n kube-system | grep ama-logs > cluster/pod-status.txt 2>&1
    # Capture ama-logs-related events with three filters: name-targeted, then a broader
    # keyword grep covering Container Insights addon, MSI auth, AMPLS, Helm rollouts, image
    # pull, scheduling, and mount failures. Empty by design when nothing is wrong.
    {
        echo "=== Events involving ama-logs pods (name match) ==="
        kubectl get events -n kube-system --sort-by='.lastTimestamp' 2>/dev/null \
            | awk 'NR==1 || /ama-logs/'
        echo ""
        echo "=== Events matching Container Insights / MSI / AMPLS / Helm / pull / schedule patterns ==="
        kubectl get events -n kube-system --sort-by='.lastTimestamp' 2>/dev/null \
            | grep -iE 'ama-logs|MSCI|amcs|ampls|aks-managed-azure-monitor-logs|addon-token-adapter|FailedMount|FailedScheduling|ImagePullBackOff|ErrImagePull|Unhealthy|BackOff'
    } > cluster/ama-logs-events.txt 2>&1
    kubectl get networkpolicy -n kube-system -o yaml > cluster/network-policies.yaml 2>&1
    kubectl get serviceaccount ama-logs -n kube-system -o yaml > cluster/serviceaccount-ama-logs.yaml 2>&1

    # Agent image version
    local agent_image=""
    if [[ -n "$ds_pod" ]]; then
        agent_image=$(kubectl get pod "$ds_pod" -n kube-system \
            -o jsonpath='{.spec.containers[?(@.name=="ama-logs")].image}' 2>/dev/null)
    fi
    if [[ -n "$agent_image" ]]; then
        echo -e "  ${Cyan}[INFO] ama-logs image: ${agent_image}${NC}" | tee -a Tool.log
        echo "ama-logs image: ${agent_image}" > cluster/agent-version.txt

        # Compare the running tag against the latest tag published on Microsoft Container Registry.
        # Linux Container Insights tags follow a 3.x.y semver pattern; anything else is ignored.
        local current_tag latest_tag versions_behind
        current_tag="${agent_image##*:}"
        if [[ "$current_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && type -p curl > /dev/null 2>&1 && type -p python3 > /dev/null 2>&1; then
            local mcr_tags_json
            mcr_tags_json=$(curl -s --connect-timeout 5 --max-time 10 \
                https://mcr.microsoft.com/v2/azuremonitor/containerinsights/ciprod/tags/list 2>/dev/null)
            if [[ -n "$mcr_tags_json" ]]; then
                read -r latest_tag versions_behind <<< "$(echo "$mcr_tags_json" | CURRENT="$current_tag" python3 -c "
import sys, json, os, re
try:
    tags = json.load(sys.stdin).get('tags',[])
    semver = sorted(
        [t for t in tags if re.match(r'^[0-9]+\.[0-9]+\.[0-9]+$', t)],
        key=lambda v: tuple(int(p) for p in v.split('.'))
    )
    if not semver:
        sys.exit(0)
    latest = semver[-1]
    cur = os.environ.get('CURRENT','')
    cur_tuple = tuple(int(p) for p in cur.split('.'))
    behind = sum(1 for t in semver if tuple(int(p) for p in t.split('.')) > cur_tuple)
    print(f'{latest} {behind}')
except Exception:
    pass
" 2>/dev/null)"
                if [[ -n "$latest_tag" ]]; then
                    echo "latest published tag: ${latest_tag} (${versions_behind:-0} releases newer than running)" >> cluster/agent-version.txt
                    if [[ "$latest_tag" == "$current_tag" ]]; then
                        echo -e "  ${Green}[OK] ama-logs image is current (${current_tag} = latest published).${NC}" | tee -a Tool.log
                    elif [[ "${versions_behind:-0}" -ge 5 ]]; then
                        echo -e "  ${Red}[ISSUE] ama-logs image is significantly out of date: running ${current_tag}, latest is ${latest_tag} (${versions_behind} releases behind).${NC}" | tee -a Tool.log
                        echo -e "          Older agent builds frequently lack DCR features, AMPLS fixes, and crash fixes." | tee -a Tool.log
                        echo -e "          -> Trigger an AKS image upgrade (the addon image cycles with cluster updates)," | tee -a Tool.log
                        echo -e "             or manually patch the ama-logs DaemonSet if the customer is pinning a tag." | tee -a Tool.log
                        ANALYSIS_FINDINGS+=("ama-logs agent image ${current_tag} is ${versions_behind} releases behind latest (${latest_tag}). Trigger an image upgrade — older builds frequently lack DCR/AMPLS fixes.")
                    else
                        echo -e "  ${Yellow}[WARN] ama-logs image is ${versions_behind} release(s) behind latest: running ${current_tag}, latest is ${latest_tag}. Consider upgrading.${NC}" | tee -a Tool.log
                    fi
                fi
            fi
        fi
    fi

    # Resource usage snapshot (requires metrics-server)
    kubectl top nodes > cluster/top-nodes.txt 2>&1 \
        || echo "(kubectl top not available - metrics-server may not be installed)" > cluster/top-nodes.txt
    kubectl top pods -n kube-system > cluster/top-pods-kube-system.txt 2>&1 \
        || echo "(kubectl top not available)" > cluster/top-pods-kube-system.txt

    local node_os
    node_os=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null)
    if [[ -n "$node_os" ]]; then
        echo -e "  ${Cyan}[INFO] Node OS: ${node_os}" | tee -a Tool.log
        echo -e "         If syslog collection is enabled, ensure node pool image is Nov 2022 or later." | tee -a Tool.log
        echo -e "         Upgrade: https://learn.microsoft.com/en-us/azure/aks/node-image-upgrade${NC}" | tee -a Tool.log
    fi

    echo -e "Complete cluster metadata collection!" | tee -a Tool.log
}

# ─── network_connectivity_check ───────────────────────────────────────────────
# Runs curl and nslookup from inside the ama-logs pod to test reachability of
# all required Azure Monitor endpoints. Tests are scoped to what is actually
# required based on workspace ID / region availability.
network_connectivity_check() {
    local test_pod="${ds_pod:-$rs_pod}"
    if [[ -z "$test_pod" ]]; then
        echo -e "${Red}[ERROR] No ama-logs pod available for network tests. Skipping.${NC}" | tee -a Tool.log
        return
    fi

    local separator="${Bold}════════════════════════════════════════════════════════${NC}"
    echo -e "\n${separator}" | tee -a Tool.log
    echo -e "${Bold} Network Connectivity Check${NC}" | tee -a Tool.log
    echo -e "${separator}" | tee -a Tool.log

    local net_log="network-connectivity.log"
    {
        echo "Network Connectivity Test - $(date)"
        echo "Test pod:     ${test_pod}"
        echo "Workspace ID: ${WORKSPACE_ID:-not provided - workspace endpoint tests skipped}"
        echo "Region:       ${CLUSTER_REGION:-not detected - region endpoint tests skipped}"
        echo "AMPLS mode:   ${USE_AMPLS}"
        echo ""
    } > "$net_log"

    # ── Proxy environment check ──────────────────────────────────────────────
    # If HTTP_PROXY/HTTPS_PROXY are set inside the pod, all curl traffic below traverses the proxy.
    # Surface these explicitly so a failing connectivity test isn't blamed on the wrong network path.
    local proxy_env
    proxy_env=$(kubectl exec "${test_pod}" -n kube-system -c ama-logs -- env 2>/dev/null \
        | grep -iE '^(HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' || true)
    if [[ -n "$proxy_env" ]]; then
        echo -e "\n${Bold}Proxy Configuration Detected:${NC}" | tee -a "$net_log"
        echo -e "  ${Cyan}The agent pod has proxy environment variables set — all outbound HTTPS traffic from the agent" | tee -a "$net_log"
        echo -e "  traverses this proxy. The connectivity tests below honor these variables, so failures may indicate" | tee -a "$net_log"
        echo -e "  proxy ACLs, TLS interception, or NO_PROXY misconfiguration rather than a direct firewall block.${NC}" | tee -a "$net_log"
        echo "$proxy_env" | sed 's/^/    /' | tee -a "$net_log"
        ANALYSIS_FINDINGS+=("Proxy env vars set in agent pod. All outbound agent traffic goes through this proxy — verify proxy allowlists and NO_PROXY excludes do not block Azure Monitor endpoints.")
    else
        echo -e "\n${Cyan}[INFO] No HTTP_PROXY/HTTPS_PROXY environment variables detected in the agent pod.${NC}" | tee -a "$net_log"
    fi

    # Check which tools are available inside the pod
    local has_curl has_nslookup
    has_curl=$(kubectl exec "${test_pod}"    -n kube-system -c ama-logs -- which curl     2>/dev/null)
    has_nslookup=$(kubectl exec "${test_pod}" -n kube-system -c ama-logs -- which nslookup 2>/dev/null)

    # Build the endpoint list based on what info we have
    local -a endpoints=()

    # Static endpoints - always required
    endpoints+=(
        "dc.services.visualstudio.com"
        "global.handler.control.monitor.azure.com"
    )

    # Region-specific endpoints - only tested in non-AMPLS mode.
    # AMPLS creates a private DNS zone for global.handler.control.monitor.azure.com but not
    # the regional endpoint, so it will always resolve to a public IP in AMPLS mode.
    if [[ -n "$CLUSTER_REGION" ]] && ! $USE_AMPLS; then
        endpoints+=(
            "${CLUSTER_REGION}.handler.control.monitor.azure.com"
        )
    fi

    # Workspace-specific ODS/OMS endpoints
    if [[ -n "$WORKSPACE_ID" ]]; then
        # Always use the non-privatelink hostnames. In AMPLS mode, the private DNS zone overrides
        # resolution of these hostnames to private IPs — the DNS test below validates that.
        # The .privatelink. form causes TLS failures (cert is for *.ods.opinsights.azure.com).
        endpoints+=(
            "${WORKSPACE_ID}.ods.opinsights.azure.com"
            "${WORKSPACE_ID}.oms.opinsights.azure.com"
        )
    fi

    # DCE-specific handler endpoint (AMPLS only) — parsed from mdsd.info.
    # When config is routed through a DCE, mdsd logs the redirect target hostname.
    local dce_test_endpoint=""
    if $USE_AMPLS; then
        dce_test_endpoint=$(grep -oP 'MCS redirected to endpoint https://\K\S+' \
            "ama-logs-daemonset-mdsd/mdsd.info" 2>/dev/null | head -1)
        if [[ -n "$dce_test_endpoint" ]]; then
            endpoints+=("$dce_test_endpoint")
        fi
    fi

    local net_failures=0
    local dns_failures=0

    echo -e "\nTesting connectivity to Azure Monitor endpoints from inside the agent pod." | tee -a "$net_log"
    echo -e "These endpoints must be reachable for the agent to ingest data:" | tee -a "$net_log"
    echo -e "  - *.handler.control.monitor.azure.com : DCR / configuration delivery" | tee -a "$net_log"
    echo -e "  - *.ods.opinsights.azure.com        : Log data ingestion endpoint" | tee -a "$net_log"
    echo -e "  - *.oms.opinsights.azure.com        : Agent heartbeat and management" | tee -a "$net_log"
    echo -e "  - dc.services.visualstudio.com      : Agent diagnostics / telemetry" | tee -a "$net_log"
    if [[ -n "$dce_test_endpoint" ]]; then
        echo -e "  ${Cyan}[INFO] DCE handler endpoint detected from mdsd.info: ${dce_test_endpoint}" | tee -a "$net_log"
        echo -e "         Testing DNS resolution and HTTPS connectivity for this endpoint.${NC}" | tee -a "$net_log"
    fi

    # ── DNS resolution tests ──────────────────────────────────────────────────
    if [[ -n "$has_nslookup" ]]; then
        echo -e "\n${Bold}DNS Resolution (nslookup):${NC}" | tee -a "$net_log"
        for ep in "${endpoints[@]}"; do
            local ns_result
            ns_result=$(kubectl exec "${test_pod}" -n kube-system -c ama-logs -- nslookup "$ep" 2>&1)

            if echo "$ns_result" | grep -qE "NXDOMAIN|can't find|server can't find|No address"; then
                echo -e "  ${Red}[FAIL] ${ep}${NC}" | tee -a "$net_log"
                echo -e "         DNS resolution failed." | tee -a "$net_log"
                if $USE_AMPLS; then
                    echo -e "         AMPLS: Verify private DNS zones are configured for this endpoint." | tee -a "$net_log"
                else
                    echo -e "         Check that DNS is not blocking resolution of Azure Monitor hostnames." | tee -a "$net_log"
                fi
                ANALYSIS_FINDINGS+=("DNS FAIL: ${ep} failed to resolve. $(if $USE_AMPLS; then echo 'AMPLS: check private DNS zone configuration.'; else echo 'Check DNS and firewall for Azure Monitor endpoints.'; fi)")
                ((dns_failures++))
            elif echo "$ns_result" | grep -q "Address"; then
                local resolved_ip
                resolved_ip=$(echo "$ns_result" | grep "Address" | tail -1 | awk '{print $2}')
                echo -e "  ${Green}[OK]   ${ep} resolves to ${resolved_ip}${NC}" | tee -a "$net_log"
                # AMPLS sanity: if AMPLS is expected, resolved IP should be RFC1918
                if $USE_AMPLS && ! echo "$resolved_ip" | grep -qE "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)"; then
                    echo -e "  ${Yellow}         [WARN] AMPLS mode but ${ep} resolved to public IP (${resolved_ip})." | tee -a "$net_log"
                    echo -e "                  Private DNS zone may be missing for this endpoint.${NC}" | tee -a "$net_log"
                    ANALYSIS_FINDINGS+=("AMPLS WARN: ${ep} resolved to public IP ${resolved_ip}. Private DNS zone may be missing.")
                fi
            else
                echo -e "  ${Yellow}[WARN] ${ep} - unexpected nslookup output (review ${net_log})${NC}" | tee -a "$net_log"
            fi
        done
    else
        echo -e "  ${Yellow}[SKIP] nslookup not found in the agent pod - DNS resolution tests skipped.${NC}" | tee -a "$net_log"
    fi

    # ── HTTPS connectivity tests ──────────────────────────────────────────────
    if [[ -n "$has_curl" ]]; then
        echo -e "\n${Bold}HTTPS Connectivity (curl):${NC}" | tee -a "$net_log"
        echo -e "  ${Cyan}Note: Any HTTP response (including 4xx) means the endpoint was reached — auth errors are expected on root paths${NC}" | tee -a "$net_log"
        for ep in "${endpoints[@]}"; do
            local http_code
            http_code=$(kubectl exec "${test_pod}" -n kube-system -c ama-logs -- \
                curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 15 --max-time 20 \
                "https://${ep}:443" 2>/dev/null)

            if [[ "$http_code" =~ ^(200|400|401|403|404|405)$ ]]; then
                # Any HTTP response (including 4xx) means the endpoint was reached — auth errors are expected on root paths
                echo -e "  ${Green}[OK]   ${ep} is reachable (HTTP ${http_code})${NC}" | tee -a "$net_log"
            elif [[ "$http_code" == "000" ]] || [[ -z "$http_code" ]]; then
                echo -e "  ${Red}[FAIL] ${ep} -> Connection failed${NC}" | tee -a "$net_log"
                echo -e "         Endpoint is unreachable. Check firewall/NSG rules for outbound HTTPS (port 443)." | tee -a "$net_log"
                if $USE_AMPLS; then
                    echo -e "         AMPLS: Verify private endpoint and DNS zone are configured for this endpoint." | tee -a "$net_log"
                fi
                ANALYSIS_FINDINGS+=("CONNECTIVITY FAIL: Cannot reach https://${ep}:443. $(if $USE_AMPLS; then echo 'AMPLS: verify private endpoint and DNS zone.'; else echo 'Check firewall/NSG outbound rules for port 443.'; fi)")
                ((net_failures++))
            else
                echo -e "  ${Yellow}[WARN] ${ep} -> HTTP ${http_code} (unexpected - review manually)${NC}" | tee -a "$net_log"
            fi
        done
    else
        echo -e "  ${Yellow}[SKIP] curl not found in the agent pod - HTTPS connectivity tests skipped.${NC}" | tee -a "$net_log"
    fi

    # ── Managed Identity token acquisition test (via IMDS) ────────────────────
    # Validates that the kubelet (or assigned) managed identity can actually obtain an OAuth
    # token for the monitor.azure.com audience used by AMCS (DCR config delivery) and DCE
    # (log ingestion). A failure here means the agent identity cannot authenticate regardless
    # of network reachability. Uses DS pod specifically because it runs hostNetwork=true and
    # therefore can reach IMDS at 169.254.169.254; RS pods cannot.
    if [[ -n "$ds_pod" ]]; then
        echo -e "\n${Bold}Managed Identity Token Test (IMDS):${NC}" | tee -a "$net_log"
        local ds_has_curl
        ds_has_curl=$(kubectl exec "${ds_pod}" -n kube-system -c ama-logs -- which curl 2>/dev/null)
        if [[ -n "$ds_has_curl" ]]; then
            local msi_test
            msi_test=$(kubectl exec "${ds_pod}" -n kube-system -c ama-logs -- \
                curl -s --connect-timeout 10 --max-time 15 -H "Metadata:true" \
                "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://monitor.azure.com/" 2>/dev/null)

            if echo "$msi_test" | grep -q '"access_token"'; then
                echo -e "  ${Green}[OK] Managed identity acquired a token for https://monitor.azure.com/${NC}" | tee -a "$net_log"
                echo -e "       The agent's identity is correctly configured to authenticate against AMCS and DCE." | tee -a "$net_log"

                # Decode the JWT payload to surface WHICH managed identity actually issued the token.
                # The agent never logs its identity directly, so this is the only way to confirm — from
                # inside the cluster — which UA/system MI is being used (and therefore which one needs
                # the Monitoring Metrics Publisher / Log Analytics Contributor role on the DCR/workspace).
                if type -p python3 > /dev/null 2>&1; then
                    local jwt_claims
                    jwt_claims=$(echo "$msi_test" | python3 -c "
import sys, json, base64
try:
    d = json.load(sys.stdin)
    token = d.get('access_token','')
    parts = token.split('.')
    if len(parts) >= 2:
        p = parts[1] + '=' * (-len(parts[1]) % 4)
        c = json.loads(base64.urlsafe_b64decode(p.encode()))
        print(c.get('appid',''))
        print(c.get('oid',''))
        print(c.get('xms_mirid',''))
except Exception:
    pass
" 2>/dev/null)
                    DETECTED_MSI_CLIENT_ID=$(echo "$jwt_claims" | sed -n '1p')
                    DETECTED_MSI_OBJECT_ID=$(echo "$jwt_claims" | sed -n '2p')
                    DETECTED_MSI_RESOURCE_ID=$(echo "$jwt_claims" | sed -n '3p')
                    if [[ -n "$DETECTED_MSI_CLIENT_ID" ]]; then
                        echo -e "       ${Cyan}Identity in use:${NC}" | tee -a "$net_log"
                        echo -e "         clientId:   ${DETECTED_MSI_CLIENT_ID}" | tee -a "$net_log"
                        [[ -n "$DETECTED_MSI_OBJECT_ID" ]]   && echo -e "         objectId:   ${DETECTED_MSI_OBJECT_ID}"   | tee -a "$net_log"
                        [[ -n "$DETECTED_MSI_RESOURCE_ID" ]] && echo -e "         resourceId: ${DETECTED_MSI_RESOURCE_ID}" | tee -a "$net_log"
                    fi
                fi
            elif echo "$msi_test" | grep -qE '"error"|"error_description"'; then
                local err_msg
                err_msg=$(echo "$msi_test" | grep -oP '"error_description"\s*:\s*"\K[^"]+' | head -1)
                [[ -z "$err_msg" ]] && err_msg=$(echo "$msi_test" | grep -oP '"error"\s*:\s*"\K[^"]+' | head -1)
                echo -e "  ${Red}[ISSUE] Managed identity failed to acquire a token for https://monitor.azure.com/${NC}" | tee -a "$net_log"
                echo -e "          IMDS error: ${err_msg:-(unparseable response)}" | tee -a "$net_log"
                echo -e "          The agent cannot authenticate to AMCS or DCE — DCR config will not deliver and" | tee -a "$net_log"
                echo -e "          ingestion will be rejected. Common causes:" | tee -a "$net_log"
                echo -e "            - Kubelet identity is missing, or addon was deployed without managed identity" | tee -a "$net_log"
                echo -e "            - User-assigned identity not attached to the node VMSS" | tee -a "$net_log"
                echo -e "            - Workload identity is configured but federated trust is misconfigured" | tee -a "$net_log"
                ANALYSIS_FINDINGS+=("MSI token acquisition failed inside ama-logs DS pod: ${err_msg:-no token returned}. The agent's managed identity cannot authenticate to monitor.azure.com — review kubelet identity attachment on the node VMSS.")
            else
                echo -e "  ${Yellow}[WARN] IMDS at 169.254.169.254 did not respond or returned an unparseable body.${NC}" | tee -a "$net_log"
                echo -e "         Either a NetworkPolicy/NSG is blocking IMDS, or the DaemonSet has lost hostNetwork." | tee -a "$net_log"
                echo -e "         IMDS is required for MSI authentication; without it the agent cannot get a token." | tee -a "$net_log"
                ANALYSIS_FINDINGS+=("IMDS (169.254.169.254) unreachable from ama-logs DS pod. Verify hostNetwork=true on the DaemonSet and that no NetworkPolicy blocks 169.254.169.254.")
            fi
        else
            echo -e "  ${Yellow}[SKIP] curl not available in DS pod - MSI token test skipped.${NC}" | tee -a "$net_log"
        fi
    else
        echo -e "\n  ${Cyan}[INFO] MSI token test skipped — no DaemonSet pod available (test requires hostNetwork to reach IMDS).${NC}" | tee -a "$net_log"
    fi

    # ── SSL inspection hint ───────────────────────────────────────────────────
    echo -e "\n${Cyan}SSL Inspection Check (run manually if data is missing despite passing tests above):" | tee -a "$net_log"
    echo -e "  kubectl exec -it ${test_pod} -n kube-system -c ama-logs -- /bin/bash" | tee -a "$net_log"
    echo -e "  openssl s_client -connect global.handler.control.monitor.azure.com:443 -showcerts 2>&1 | grep -E 'issuer|subject'" | tee -a "$net_log"
    echo -e "  Expected: certificate issued by Microsoft/DigiCert." | tee -a "$net_log"
    echo -e "  If a third-party CA appears: SSL inspection is intercepting agent traffic and must be" | tee -a "$net_log"
    echo -e "  bypassed for all Azure Monitor endpoints.${NC}" | tee -a "$net_log"

    # ── Summary ───────────────────────────────────────────────────────────────
    echo -e "" | tee -a "$net_log"
    local total_failures=$((net_failures + dns_failures))
    if [[ $total_failures -gt 0 ]]; then
        echo -e "${Red}[NETWORK SUMMARY] ${net_failures} HTTPS failure(s) and ${dns_failures} DNS failure(s) detected.${NC}" | tee -a "$net_log" Tool.log
        if $USE_AMPLS; then
            echo -e "${Yellow}  AMPLS mode: Verify private endpoints and private DNS zones for all failing endpoints.${NC}" | tee -a "$net_log"
        else
            echo -e "${Yellow}  Check firewall rules and NSG outbound policies for port 443 to the failing endpoints.${NC}" | tee -a "$net_log"
        fi
    else
        echo -e "${Green}[NETWORK SUMMARY] All Azure Monitor endpoints are reachable from the agent pod.${NC}" | tee -a "$net_log" Tool.log
        echo -e "${Cyan}  DNS is resolving correctly and no firewall or NSG is blocking outbound HTTPS (port 443).${NC}" | tee -a "$net_log"
        echo -e "${Cyan}  If data is still missing in the workspace, the issue is likely in the agent pipeline${NC}" | tee -a "$net_log"
        echo -e "${Cyan}  rather than network connectivity — review the log analysis section below.${NC}" | tee -a "$net_log"
    fi

    echo -e "Network connectivity results saved to ${net_log}" | tee -a Tool.log
}

# ─── analyze_collected_logs ───────────────────────────────────────────────────
# Scans the collected log files for known error patterns and prints actionable
# findings. This runs after all logs are copied so we can read them locally.
analyze_collected_logs() {
    local separator="${Bold}════════════════════════════════════════════════════════${NC}"
    echo -e "\n${separator}" | tee -a Tool.log
    echo -e "${Bold} Post-Collection Log Analysis${NC}" | tee -a Tool.log
    echo -e "${separator}" | tee -a Tool.log
    echo -e "Scanning the collected log files for known error patterns." | tee -a Tool.log
    echo -e "Each log file covers a specific part of the data collection pipeline:" | tee -a Tool.log
    echo -e "  mdsd.err       : errors from the core agent engine (auth, network, TLS)" | tee -a Tool.log
    echo -e "  mdsd.warn      : warnings from the core agent engine (transient or recoverable issues)" | tee -a Tool.log
    echo -e "  mdsd.qos       : per-table throughput — confirms data is actually being sent" | tee -a Tool.log
    echo -e "  fluent-bit     : container log reader — collects logs from /var/log/containers/" | tee -a Tool.log
    echo -e "  fluentd        : pipeline router — forwards data through the processing chain" | tee -a Tool.log

    local analysis_log="analysis-findings.log"
    echo "Post-Collection Log Analysis - $(date)" > "$analysis_log"
    echo "Pod: DS=${ds_pod:-none} RS=${rs_pod:-none}" >> "$analysis_log"
    echo "" >> "$analysis_log"

    # Helper: scan a file for patterns and report findings
    # Only flags if the pattern appears in the last 50 lines (ongoing issue).
    # A single past error that did not recur is noted as informational only.
    # Optional 6th arg: min_count — minimum recent occurrences before flagging as [ISSUE].
    # Below that threshold, occurrences are noted as [INFO] (occasional, not continuous).
    # Usage: scan_log <file> <label> <pattern> <message> <action> [min_count]
    scan_log() {
        local file="$1" label="$2" pattern="$3" message="$4" action="$5" min_count="${6:-1}"
        [[ ! -f "$file" ]] && return 1

        local recent_match
        recent_match=$(tail -50 "$file" | grep -ciE "$pattern" 2>/dev/null)
        recent_match="${recent_match:-0}"

        if [[ "$recent_match" -eq 0 ]]; then
            # Error appeared earlier but is no longer in recent entries — likely recovered
            if grep -qiE "$pattern" "$file" 2>/dev/null; then
                echo -e "  ${Cyan}[INFO] ${label}: past '${message}' detected but not in recent entries — may have self-resolved.${NC}" | tee -a "$analysis_log"
            fi
            return 1
        fi

        if [[ "$recent_match" -lt "$min_count" ]]; then
            echo -e "  ${Cyan}[INFO] ${label}: occasional '${message}' (${recent_match} in last 50 lines — below threshold for a continuous issue).${NC}" | tee -a "$analysis_log"
            return 1
        fi

        echo -e "  ${Red}[ISSUE] ${label}: ${message} (${recent_match} recent occurrence(s))${NC}" | tee -a "$analysis_log"
        tail -50 "$file" | grep -iE "$pattern" | tail -5 | sed 's/^/    /' | tee -a "$analysis_log"
        echo -e "  ${Yellow}  -> ${action}${NC}" | tee -a "$analysis_log"
        ANALYSIS_FINDINGS+=("${label}: ${message} | ${action}")
        return 0
    }

    local found_any=false

    # ── mdsd.info pipeline-success parse ──────────────────────────────────────
    # Two specific log lines in mdsd.info prove the end-to-end Azure pipeline is working
    # without needing any Azure CLI access:
    #   1. "MCS redirected to endpoint https://<dce-fqdn>"   -> AMCS reached + DCE association is live
    #   2. "Retrieved gig token for configuration id [dcr-…] channel id [ods-…]"
    #                                                         -> identity auth + DCR delivery + ingestion
    #                                                            token issuance all succeeded end-to-end
    # When both are present, AMCS/DCE/DCR/MSI are all proven from inside the cluster — the
    # azure_config_check section becomes a reconciliation pass rather than a primary check.
    for mdsd_info in ama-logs-daemonset-mdsd/mdsd.info ama-logs-replicaset-mdsd/mdsd.info; do
        [[ ! -f "$mdsd_info" ]] && continue
        echo -e "\nChecking ${mdsd_info} for proof of end-to-end AMCS / DCE / DCR pipeline..." | tee -a "$analysis_log"

        local mcs_line gig_line
        mcs_line=$(grep -m1 "MCS redirected to endpoint" "$mdsd_info" 2>/dev/null)
        gig_line=$(grep -m1 "Retrieved gig token for configuration id" "$mdsd_info" 2>/dev/null)

        # The 'gig token' line is the single, mode-independent proof that DCR config was
        # delivered and an ingestion token was issued. The 'MCS redirected to endpoint'
        # line only appears in AMPLS mode where AMCS hands the agent a DCE FQDN — public-
        # network clusters never log it and that's expected, not a failure.
        if [[ -n "$gig_line" ]]; then
            local dcr_id_seen
            dcr_id_seen=$(echo "$gig_line" | grep -oP 'configuration id \[\K[^]]+' | head -1)
            echo -e "  ${Green}[OK] End-to-end pipeline proven via mdsd.info:${NC}" | tee -a "$analysis_log"
            if [[ -n "$mcs_line" ]]; then
                local mcs_dce
                mcs_dce=$(echo "$mcs_line" | grep -oE 'https://[^ ]+' | head -1)
                echo -e "       MCS -> DCE redirect:  ${mcs_dce:-(captured)} (AMPLS path)" | tee -a "$analysis_log"
            else
                echo -e "       Path:                 public network (no MCS->DCE redirect — direct to AMCS)" | tee -a "$analysis_log"
            fi
            echo -e "       DCR config delivered: ${dcr_id_seen:-(captured)}" | tee -a "$analysis_log"
            echo -e "       Ingestion (gig) token successfully retrieved." | tee -a "$analysis_log"
        else
            if [[ -n "$mcs_line" ]]; then
                # AMPLS mode: MCS redirect happened but token retrieval failed.
                echo -e "  ${Red}[ISSUE] No 'Retrieved gig token' line found in ${mdsd_info}.${NC}" | tee -a "$analysis_log"
                echo -e "          MCS redirect succeeded but the agent could not get an ingestion token from" | tee -a "$analysis_log"
                echo -e "          the DCE. This means MSI auth to the DCE is failing OR the DCE is not a" | tee -a "$analysis_log"
                echo -e "          connected resource in the AMPLS scope. Cross-check the DCE AMPLS section." | tee -a "$analysis_log"
                ANALYSIS_FINDINGS+=("${mdsd_info}: MCS redirect logged but no gig token retrieved — DCE auth or DCE-AMPLS association is failing. Cross-check the DCE AMPLS section of azure-config-check.log.")
                found_any=true
            else
                # No pipeline proof at all — mode-aware remediation hints.
                echo -e "  ${Red}[ISSUE] No 'Retrieved gig token' line found in ${mdsd_info}.${NC}" | tee -a "$analysis_log"
                echo -e "          The agent never received DCR config or an ingestion token. Likely causes:" | tee -a "$analysis_log"
                if $USE_AMPLS; then
                    echo -e "            - global.handler.control.monitor.azure.com is blocked by firewall/NSG" | tee -a "$analysis_log"
                    echo -e "            - AMPLS misconfigured (DCE/workspace not connected resources in the scope)" | tee -a "$analysis_log"
                    echo -e "            - No DCR association exists on the cluster resource" | tee -a "$analysis_log"
                    ANALYSIS_FINDINGS+=("${mdsd_info}: no AMCS pipeline proof — agent never reached AMCS or AMCS returned no config. Review reachability of global.handler.control.monitor.azure.com and the cluster's AMPLS/DCR association.")
                else
                    echo -e "            - global.handler.control.monitor.azure.com is blocked by firewall/NSG" | tee -a "$analysis_log"
                    echo -e "            - Cluster has no DCR association (DCRA missing on the cluster resource)" | tee -a "$analysis_log"
                    echo -e "            - Managed identity is missing the required role on the DCR" | tee -a "$analysis_log"
                    ANALYSIS_FINDINGS+=("${mdsd_info}: no AMCS pipeline proof — agent never received DCR config. Review reachability of global.handler.control.monitor.azure.com and the cluster's DCR association.")
                fi
                found_any=true
            fi
        fi
    done

    # ── mdsd.err ─────────────────────────────────────────────────────────────
    for mdsd_err in ama-logs-daemonset-mdsd/mdsd.err ama-logs-replicaset-mdsd/mdsd.err; do
        [[ ! -f "$mdsd_err" ]] && continue
        echo -e "\nChecking ${mdsd_err} for network, auth, and TLS errors..." | tee -a "$analysis_log"

        if scan_log "$mdsd_err" "$mdsd_err" \
            "connection refused|failed to connect|network unreachable|NXDOMAIN|could not resolve|timed out|connection reset" \
            "Network connectivity errors detected." \
            "Run network connectivity tests or check firewall rules for Azure Monitor endpoints. Review the network-connectivity.log in this archive."; then
            found_any=true
        elif scan_log "$mdsd_err" "$mdsd_err" \
            "Data collection endpoint must be used to access configuration over private link" \
            "AMPLS private link 403: DCE is not a connected resource in the AMPLS scope." \
            "Add the DCE as a scoped resource in the AMPLS scope so the agent can fetch its DCR configuration over the private link. Review the azure-config-check.log DCE section."; then
            found_any=true
        elif scan_log "$mdsd_err" "$mdsd_err" \
            "403|InvalidAccess|Unauthorized|Authentication failed|forbidden|Access denied" \
            "Authentication/authorization errors (403) detected." \
            "If AMPLS is in use, verify the workspace and DCE are connected resources in the AMPLS scope. Check that the cluster managed identity exists and the DCR association is valid."; then
            found_any=true
        elif scan_log "$mdsd_err" "$mdsd_err" \
            "certificate|SSL|TLS|cert verify|x509" \
            "TLS/certificate errors detected." \
            "SSL inspection may be intercepting Azure Monitor traffic. Run: openssl s_client -connect <endpoint>:443 -showcerts and verify the certificate is issued by Microsoft/DigiCert."; then
            found_any=true
        else
            echo -e "  ${Green}[OK] No critical errors in mdsd — the agent's core engine is operating normally.${NC}" | tee -a "$analysis_log"
        fi
    done

    # ── mdsd.warn ────────────────────────────────────────────────────────────
    for mdsd_warn in ama-logs-daemonset-mdsd/mdsd.warn ama-logs-replicaset-mdsd/mdsd.warn; do
        [[ ! -f "$mdsd_warn" ]] && continue
        echo -e "\nChecking ${mdsd_warn} for unexpected warnings..." | tee -a "$analysis_log"

        # The systemctl-not-found message is always expected in a container (no init system).
        # Filter it out so it doesn't obscure real warnings.
        local warn_filtered
        warn_filtered=$(grep -viE "CheckIfHimdsServiceInstalled|systemctl executable was not found" "$mdsd_warn" 2>/dev/null)

        if [[ -z "$warn_filtered" ]]; then
            echo -e "  ${Green}[OK] No unexpected warnings in mdsd.warn.${NC}" | tee -a "$analysis_log"
        else
            local warn_tmp
            warn_tmp=$(mktemp)
            echo "$warn_filtered" > "$warn_tmp"

            if scan_log "$warn_tmp" "$mdsd_warn" \
                "retry|failed|timeout|certificate|SSL|TLS|x509|auth|unauthorized|forbidden|connection" \
                "Unexpected warnings detected in mdsd.warn." \
                "Review the warnings above — they may indicate intermittent connectivity, auth, or TLS issues." \
                1; then
                found_any=true
            else
                local remaining
                remaining=$(wc -l < "$warn_tmp")
                echo -e "  ${Cyan}[INFO] ${mdsd_warn}: ${remaining} warning(s) present but no known error patterns matched — review manually if issues persist.${NC}" | tee -a "$analysis_log"
            fi
            rm -f "$warn_tmp"
        fi
    done

    # ── mdsd.qos - data flow confirmation ────────────────────────────────────
    for qos_file in ama-logs-daemonset-mdsd/mdsd.qos ama-logs-replicaset-mdsd/mdsd.qos; do
        [[ ! -f "$qos_file" ]] && continue
        echo -e "\nChecking ${qos_file} to confirm data is flowing to the workspace..." | tee -a "$analysis_log"

        # Parse CSV: fields are Operation,Object,...,TotalRowsRead,TotalRowsSent (11 fields total)
        # Skip comment/header lines (start with #). Only MaRunTaskLocal lines represent per-stream task metrics.
        local qos_parsed
        qos_parsed=$(awk -F',' '
            /^#/ { next }
            $1 == "MaRunTaskLocal" {
                n = split($2, a, ":")
                stream = a[n]
                sent = $11 + 0
                if (sent > 0) { flowing++; flowing_names = flowing_names (flowing_names ? ", " : "") stream }
                else zero++
            }
            END { print (flowing+0), (zero+0) }
        ' "$qos_file" 2>/dev/null)

        local flowing_count zero_count
        read -r flowing_count zero_count <<< "$qos_parsed"

        if [[ "${flowing_count:-0}" -eq 0 && "${zero_count:-0}" -eq 0 ]]; then
            echo -e "  ${Yellow}[WARN] ${qos_file} contains no MaRunTaskLocal entries." | tee -a "$analysis_log"
            echo -e "         This could mean the agent just started, the log was recently rotated, or no data" | tee -a "$analysis_log"
            echo -e "         has been transmitted yet. If collection has been running for >10 minutes, check" | tee -a "$analysis_log"
            echo -e "         mdsd.err for errors that may be preventing data from being sent.${NC}" | tee -a "$analysis_log"
        else
            if [[ "${flowing_count:-0}" -gt 0 ]]; then
                echo -e "  ${Green}[OK] Data is actively flowing — ${flowing_count} stream(s) with TotalRowsSent > 0.${NC}" | tee -a "$analysis_log"
            fi
            if [[ "${zero_count:-0}" -gt 0 ]]; then
                echo -e "  ${Cyan}[INFO] ${zero_count} stream(s) show 0 rows sent. This may be expected — for example," | tee -a "$analysis_log"
                echo -e "         ContainerLog will be 0 if ContainerLogV2 is the active log table, and inventory/event" | tee -a "$analysis_log"
                echo -e "         streams will be 0 if no data was generated in the collection window.${NC}" | tee -a "$analysis_log"
                if [[ "${flowing_count:-0}" -eq 0 ]]; then
                    echo -e "  ${Red}[ISSUE] No streams have any rows sent. Check mdsd.err for errors blocking data transmission.${NC}" | tee -a "$analysis_log"
                    ANALYSIS_FINDINGS+=("${qos_file}: all streams show 0 TotalRowsSent. Data is not being transmitted. Review mdsd.err for pipeline errors.")
                    found_any=true
                fi
            fi
        fi
    done

    # ── fluent-bit forwarding to MDSD ─────────────────────────────────────────
    local fbit_oms="ama-logs-daemonset/fluent-bit-out-oms-runtime.log"
    if [[ -f "$fbit_oms" ]]; then
        echo -e "\nChecking ${fbit_oms} — fluent-bit's output plugin that forwards container logs to the agent..." | tee -a "$analysis_log"
        if scan_log "$fbit_oms" "$fbit_oms" \
            "retry|error|connection refused|failed|exception" \
            "Fluent-bit output errors - failed to forward data to MDSD." \
            "Check if MDSD is running (review process_*.txt) and check mdsd.err for MDSD-side errors." \
            5; then
            found_any=true
        else
            echo -e "  ${Green}[OK] Fluent-bit is successfully forwarding container logs to the agent pipeline.${NC}" | tee -a "$analysis_log"
        fi
    fi

    # ── fluent-bit container log access ───────────────────────────────────────
    local fbit_log="ama-logs-daemonset/fluent-bit.log"
    if [[ -f "$fbit_log" ]]; then
        echo -e "\nChecking ${fbit_log} — fluent-bit's ability to read container log files from the node..." | tee -a "$analysis_log"
        if scan_log "$fbit_log" "$fbit_log" \
            "permission denied|error opening|cannot open" \
            "File permission errors - cannot read container log files." \
            "Check node-level permissions on /var/log/containers/ and /var/log/pods/. A privileged pod security policy may be blocking log access."; then
            found_any=true
        else
            echo -e "  ${Green}[OK] Fluent-bit has the necessary permissions to read container log files on the node.${NC}" | tee -a "$analysis_log"
        fi
    fi

    # ── OOMKill / restart count ───────────────────────────────────────────────
    for desc in ama-logs-daemonset/describe_*.txt ama-logs-replicaset/describe_*.txt ama-logs-windows-daemonset/describe_*.txt; do
        [[ ! -f "$desc" ]] && continue
        echo -e "\nAnalyzing ${desc} for restarts, OOMKill, and probe failures..." | tee -a "$analysis_log"

        local oom_count restart_count
        oom_count=$(grep -c "OOMKilled" "$desc" 2>/dev/null)
        oom_count="${oom_count:-0}"
        # Sum all "Restart Count: N" values found in the describe output
        restart_count=$(grep -oP "Restart Count:\s+\K[0-9]+" "$desc" 2>/dev/null \
            | awk '{s+=$1} END {print s+0}')

        if [[ "$oom_count" -gt 0 ]]; then
            echo -e "  ${Red}[ISSUE] OOMKilled detected in ${desc} (${oom_count} occurrence(s)).${NC}" | tee -a "$analysis_log"
            echo -e "         The ama-logs container was terminated by the Kubernetes OOM killer due to exceeding its memory limit." | tee -a "$analysis_log"
            echo -e "         When this happens the agent restarts, causing a gap in data collection." | tee -a "$analysis_log"
            echo -e "         Consider increasing memory limits on the ama-logs DaemonSet, or reducing" | tee -a "$analysis_log"
            echo -e "         collection scope via the ConfigMap (e.g. namespace filtering, collection interval).${NC}" | tee -a "$analysis_log"
            ANALYSIS_FINDINGS+=("OOMKilled in ${desc}: container killed by memory pressure. Review resource limits or reduce collection scope.")
            found_any=true
        elif [[ "$restart_count" -gt 3 ]]; then
            # Distinguish a real crash from a graceful restart (kubectl rollout restart,
            # a ConfigMap update that trips the inotify-driven liveness probe, a node
            # drain, etc.). Three "graceful" signals — any one is enough:
            #   - Last State Reason = Completed
            #   - Last State ExitCode = 0 or 143 (SIGTERM = 128+15 — what kubelet sends
            #     when killing a container for liveness-probe failure or pod termination)
            #   - Last State Message mentions inotify / config change — the agent's own
            #     way of telling us "I shut myself down to reload config"
            local last_reason last_exit last_msg
            last_reason=$(awk '
                /^[[:space:]]*Last State:[[:space:]]*Terminated/ { capture=1; next }
                capture && /^[[:space:]]*Reason:/                { print $2; exit }
            ' "$desc" 2>/dev/null)
            last_exit=$(awk '
                /^[[:space:]]*Last State:[[:space:]]*Terminated/ { capture=1; next }
                capture && /^[[:space:]]*Exit Code:/             { print $3; exit }
            ' "$desc" 2>/dev/null)
            last_msg=$(awk '
                /^[[:space:]]*Last State:[[:space:]]*Terminated/ { capture=1; next }
                capture && /^[[:space:]]*Message:/ { sub(/^[[:space:]]*Message:[[:space:]]*/, ""); print; exit }
            ' "$desc" 2>/dev/null)

            local agent_self_restart=0
            if echo "$last_msg" | grep -qiE "config[[:space:]]*changed|inotifyoutput|config[[:space:]]*map[[:space:]]*updated"; then
                agent_self_restart=1
            fi

            if [[ "$agent_self_restart" -eq 1 ]]; then
                echo -e "  ${Cyan}[INFO] Restart count ${restart_count} in ${desc} — the agent self-terminated to reload config.${NC}" | tee -a "$analysis_log"
                echo -e "         Last State Message: ${last_msg}" | tee -a "$analysis_log"
                echo -e "         This is the standard reaction to a ConfigMap update (the inotify watcher trips the" | tee -a "$analysis_log"
                echo -e "         liveness probe, kubelet SIGTERMs the container, mdsd restarts and picks up the new config). Not flagged." | tee -a "$analysis_log"
            elif [[ "$last_reason" == "Completed" || "$last_exit" == "0" || "$last_exit" == "143" ]]; then
                echo -e "  ${Cyan}[INFO] Restart count ${restart_count} in ${desc} but last termination was graceful (Reason=${last_reason:-?}, ExitCode=${last_exit:-?}).${NC}" | tee -a "$analysis_log"
                echo -e "         Typically caused by a ConfigMap update, 'kubectl rollout restart', or a node drain — not a crash. Not flagged." | tee -a "$analysis_log"
            else
                echo -e "  ${Yellow}[WARN] Elevated restart count (${restart_count}) detected in ${desc}." | tee -a "$analysis_log"
                echo -e "         Last termination: Reason=${last_reason:-unknown}, ExitCode=${last_exit:-unknown} — looks like a crash." | tee -a "$analysis_log"
                [[ -n "$last_msg" ]] && echo -e "         Last State Message: ${last_msg}" | tee -a "$analysis_log"
                echo -e "         Check previous pod logs (logs_*_previous.txt) for the crash reason.${NC}" | tee -a "$analysis_log"
                ANALYSIS_FINDINGS+=("High restart count (${restart_count}) in ${desc} (Reason=${last_reason:-unknown}, ExitCode=${last_exit:-unknown}). Review logs_*_previous.txt.")
                found_any=true
            fi
        else
            echo -e "  ${Green}[OK] No OOMKill events detected. Restart count: ${restart_count}.${NC}" | tee -a "$analysis_log"
        fi

        local probe_count
        probe_count=$(grep -ciE "Liveness probe failed|Readiness probe failed" "$desc" 2>/dev/null)
        probe_count="${probe_count:-0}"
        if [[ "$probe_count" -gt 0 ]]; then
            # The probe-failure event line follows the kubectl-events format
            #   "  Warning  Unhealthy  <Age>  (xN over Ym)  kubelet  spec.containers{X}: <Message>"
            # where <Age> is the most-recent occurrence age. Treat the failure as benign
            # if either:
            #   (a) the Message field contains an agent-side config-change marker, OR
            #   (b) the age is older than 10 minutes AND the container is now Running
            #       Ready (the failure already led to a successful restart and the agent
            #       has been stable since).
            local last_probe last_age last_age_min=0 is_config_triggered=0
            last_probe=$(grep -iE "Liveness probe failed|Readiness probe failed" "$desc" | tail -1)
            last_age=$(echo "$last_probe" | awk '{print $3}')
            if [[ "$last_age" =~ ^([0-9]+)([smhd])$ ]]; then
                local _n="${BASH_REMATCH[1]}" _u="${BASH_REMATCH[2]}"
                case "$_u" in
                    s) last_age_min=$(( _n / 60 )) ;;
                    m) last_age_min=$_n ;;
                    h) last_age_min=$(( _n * 60 )) ;;
                    d) last_age_min=$(( _n * 1440 )) ;;
                esac
            fi
            if echo "$last_probe" | grep -qiE "config[[:space:]]*map[[:space:]]*updated|inotifyoutput|config[[:space:]]*changed"; then
                is_config_triggered=1
            fi

            if [[ "$is_config_triggered" -eq 1 ]]; then
                echo -e "  ${Cyan}[INFO] Probe failures in ${desc} (${probe_count} occurrence(s)) are agent-driven ConfigMap reloads, not a real fault:${NC}" | tee -a "$analysis_log"
                echo -e "         ${last_probe}" | tee -a "$analysis_log"
                echo -e "         The agent's inotify watcher detected a ConfigMap change and tripped the liveness probe on purpose to reload. Not flagged." | tee -a "$analysis_log"
            elif [[ "$last_age_min" -gt 10 ]]; then
                echo -e "  ${Cyan}[INFO] Probe failures in ${desc} (${probe_count} occurrence(s)) but the most recent one was ${last_age_min}m ago and the container is now Running Ready.${NC}" | tee -a "$analysis_log"
                echo -e "         ${last_probe}" | tee -a "$analysis_log"
                echo -e "         Likely stale — a ConfigMap update, rollout restart, or transient issue that already self-resolved. Not flagged." | tee -a "$analysis_log"
            else
                echo -e "  ${Yellow}[WARN] Liveness/Readiness probe failures detected in ${desc} (${probe_count} occurrence(s)).${NC}" | tee -a "$analysis_log"
                echo -e "         Probe failures usually precede OOMKill events and indicate the agent (mdsd or fluent-bit)" | tee -a "$analysis_log"
                echo -e "         is hanging or slow to respond. Common causes: high log throughput backing up the pipeline," | tee -a "$analysis_log"
                echo -e "         under-sized memory limits, or a downstream endpoint that is intermittently unreachable." | tee -a "$analysis_log"
                echo -e "         Last probe failure event: ${last_probe}" | tee -a "$analysis_log"
                ANALYSIS_FINDINGS+=("Probe failures (${probe_count}) in ${desc}. Agent is hanging or slow to respond — review memory limits and downstream endpoint reachability.")
                found_any=true
            fi
        fi

        # ── addon-token-adapter sidecar health ────────────────────────────────
        # The addon-token-adapter sidecar is the AKS component that brokers MSI tokens to
        # the ama-logs container. If this sidecar isn't Ready or is crash-looping, MSI auth
        # silently fails before mdsd even starts — and the failure won't show up in mdsd.err
        # because mdsd never gets a token to fail with. Worth checking explicitly per pod.
        local adapter_block
        adapter_block=$(awk '
            /^  addon-token-adapter:/ { capture=1; next }
            capture && /^  [a-zA-Z]/  { exit }
            capture                   { print }
        ' "$desc")

        if [[ -n "$adapter_block" ]]; then
            local adapter_ready adapter_restarts adapter_state
            adapter_ready=$(echo    "$adapter_block" | awk '/^[[:space:]]*Ready:/         {print $2; exit}')
            adapter_restarts=$(echo "$adapter_block" | awk '/^[[:space:]]*Restart Count:/ {print $3; exit}')
            adapter_state=$(echo    "$adapter_block" | awk '/^[[:space:]]*State:/         {print $2; exit}')
            adapter_restarts="${adapter_restarts:-0}"

            if [[ "$adapter_ready" != "True" ]] || [[ "$adapter_state" != "Running" ]]; then
                echo -e "  ${Red}[ISSUE] addon-token-adapter sidecar is NOT healthy in ${desc}:${NC}" | tee -a "$analysis_log"
                echo -e "          Ready=${adapter_ready:-unknown}  State=${adapter_state:-unknown}  RestartCount=${adapter_restarts}" | tee -a "$analysis_log"
                echo -e "          This sidecar brokers MSI tokens to ama-logs. While it is down, the agent" | tee -a "$analysis_log"
                echo -e "          cannot authenticate to AMCS/DCE regardless of network reachability." | tee -a "$analysis_log"
                echo -e "          -> kubectl logs $(basename "${desc#*describe_}" .txt) -n kube-system -c addon-token-adapter" | tee -a "$analysis_log"
                ANALYSIS_FINDINGS+=("addon-token-adapter sidecar unhealthy in ${desc} (Ready=${adapter_ready:-unknown}, State=${adapter_state:-unknown}). MSI auth will fail; inspect the sidecar logs.")
                found_any=true
            elif [[ "$adapter_restarts" -gt 3 ]]; then
                # Same rolling-restart guard as the ama-logs container above: a graceful
                # exit (Reason=Completed, ExitCode=0/143, or Message mentions a config
                # change) usually means the pod was recreated by a ConfigMap update or
                # rollout restart, not crashing.
                local sa_reason sa_exit sa_msg
                sa_reason=$(echo "$adapter_block" | awk '
                    /^[[:space:]]*Last State:[[:space:]]*Terminated/ { capture=1; next }
                    capture && /^[[:space:]]*Reason:/                { print $2; exit }
                ')
                sa_exit=$(echo "$adapter_block" | awk '
                    /^[[:space:]]*Last State:[[:space:]]*Terminated/ { capture=1; next }
                    capture && /^[[:space:]]*Exit Code:/             { print $3; exit }
                ')
                sa_msg=$(echo "$adapter_block" | awk '
                    /^[[:space:]]*Last State:[[:space:]]*Terminated/ { capture=1; next }
                    capture && /^[[:space:]]*Message:/ { sub(/^[[:space:]]*Message:[[:space:]]*/, ""); print; exit }
                ')
                local sa_graceful=0
                [[ "$sa_reason" == "Completed" || "$sa_exit" == "0" || "$sa_exit" == "143" ]] && sa_graceful=1
                echo "$sa_msg" | grep -qiE "config[[:space:]]*changed|inotifyoutput|config[[:space:]]*map[[:space:]]*updated" && sa_graceful=1
                if [[ "$sa_graceful" -eq 1 ]]; then
                    echo -e "  ${Cyan}[INFO] addon-token-adapter restart count ${adapter_restarts} in ${desc} but last termination was graceful (Reason=${sa_reason:-?}, ExitCode=${sa_exit:-?}). Likely a rolling restart — not flagged.${NC}" | tee -a "$analysis_log"
                else
                    echo -e "  ${Yellow}[WARN] addon-token-adapter has restarted ${adapter_restarts} time(s) in ${desc}.${NC}" | tee -a "$analysis_log"
                    echo -e "         Last termination: Reason=${sa_reason:-unknown}, ExitCode=${sa_exit:-unknown}." | tee -a "$analysis_log"
                    [[ -n "$sa_msg" ]] && echo -e "         Last State Message: ${sa_msg}" | tee -a "$analysis_log"
                    echo -e "         Each restart drops MSI tokens in flight; bursts of 401/403s in mdsd.err around" | tee -a "$analysis_log"
                    echo -e "         restart times are explained by this. Inspect the sidecar logs for the cause." | tee -a "$analysis_log"
                    ANALYSIS_FINDINGS+=("addon-token-adapter has restarted ${adapter_restarts} times in ${desc} (Reason=${sa_reason:-unknown}, ExitCode=${sa_exit:-unknown}). May explain transient 401/403s in mdsd.err.")
                    found_any=true
                fi
            else
                echo -e "  ${Green}[OK] addon-token-adapter sidecar is healthy (Ready=True, restarts=${adapter_restarts}).${NC}" | tee -a "$analysis_log"
            fi
        fi
    done

    # ── Node conditions (Disk/Memory/PID pressure) ───────────────────────────
    local node_cond_file="cluster/node-conditions.txt"
    if [[ -f "$node_cond_file" ]]; then
        echo -e "\nAnalyzing node conditions for pressure events (Disk/Memory/PID)..." | tee -a "$analysis_log"
        local pressured
        pressured=$(grep -iE "DiskPressure|MemoryPressure|PIDPressure" "$node_cond_file" 2>/dev/null)
        if [[ -n "$pressured" ]]; then
            echo -e "  ${Red}[ISSUE] One or more nodes are reporting active pressure conditions:${NC}" | tee -a "$analysis_log"
            echo "$pressured" | sed 's/^/    /' | tee -a "$analysis_log"
            echo -e "  ${Yellow}  -> DiskPressure breaks fluent-bit checkpoints and causes container log drops on the affected node." | tee -a "$analysis_log"
            echo -e "     MemoryPressure leads to OOMKill of the agent. PIDPressure starves the agent's worker threads." | tee -a "$analysis_log"
            echo -e "     Free disk on the affected nodes, increase node size, or scale the node pool to relieve pressure.${NC}" | tee -a "$analysis_log"
            ANALYSIS_FINDINGS+=("Node pressure conditions active on one or more nodes (see cluster/node-conditions.txt). DiskPressure causes fluent-bit log drops; MemoryPressure causes agent OOMKill. Investigate the affected nodes.")
            found_any=true
        else
            echo -e "  ${Green}[OK] No nodes are reporting DiskPressure, MemoryPressure, or PIDPressure.${NC}" | tee -a "$analysis_log"
        fi
    fi

    # ── container-azm-ms-agentconfig ConfigMap ────────────────────────────────
    local cm_file="cluster/container-azm-ms-agentconfig.yaml"
    if [[ -f "$cm_file" ]]; then
        echo -e "\nAnalyzing ${cm_file}..." | tee -a "$analysis_log"
        local cm_issues=0

        # Collection disabled. Several settings are FALSE by default in the upstream
        # ConfigMap template (microsoft/Docker-Provider container-azm-ms-agentconfig.yaml).
        # Skip the WARN when the section matches a known default-false setting so a
        # customer who uploaded an unmodified default ConfigMap doesn't get a screenful
        # of false positives. Surface those as INFO instead.
        local default_disabled_re='(enrich_container_logs|collect_all_kube_events|collect_kube_system_pv_metrics|health_model|azure_network_policy_manager|azure_subnet_ip_usage|kappie_basic_metrics|multi_tenancy)'
        # Walk the TOML-in-YAML body once with awk, tracking the active section header so
        # each "enabled = false" line is attributed to its true section. Two YAML-shaped
        # gotchas we have to defend against:
        #   1. TOML comments inside the ConfigMap (lines starting with '#') are
        #      documentation, not real settings — we must skip them, otherwise a line
        #      like '# enabled = false' is mis-flagged as a disabled collection.
        #   2. kubectl prints fields like 'agent-settings: "..."' as double-quoted YAML
        #      scalars where '\n' is a literal escape inside one logical value. The YAML
        #      printer wraps long values across lines for readability, which can leave a
        #      commented-out '# [agent_settings.fbit_config]' looking like a real
        #      '[agent_settings.fbit_config]' at the start of a continuation line (the
        #      '#' is sitting at the end of the previous YAML line). We filter those out
        #      by requiring section-header lines to end with ']' (no trailing content) —
        #      real TOML headers in a literal-block scalar sit alone on their line.
        while IFS=$'\t' read -r section setting_line; do
            [[ -z "$section" && -z "$setting_line" ]] && continue
            if [[ "$section" =~ $default_disabled_re ]]; then
                echo -e "  ${Cyan}[INFO] '${section}' disabled — matches upstream default, not a finding.${NC}" | tee -a "$analysis_log"
            else
                echo -e "  ${Yellow}[WARN] Collection disabled: ${setting_line// /} (section: ${section:-unknown})${NC}" | tee -a "$analysis_log"
                ANALYSIS_FINDINGS+=("ConfigMap: collection disabled for section '${section:-unknown}' via 'enabled = false'. Verify this is intentional.")
                ((cm_issues++)); found_any=true
            fi
        done < <(awk '
            /^[[:space:]]*\[(log_collection_settings|metric_collection_settings|agent_settings|integrations)\.[^]]+\][[:space:]]*$/ {
                line = $0
                sub(/^[[:space:]]*\[[^.]*\./, "", line)
                sub(/\][[:space:]]*$/, "", line)
                section = line
                next
            }
            /^[[:space:]]*#/ { next }
            # Skip YAML double-quoted-scalar lines — they contain literal "\n" escape
            # sequences and embed multiple logical TOML lines into one awk record. Any
            # "enabled = false" substring inside such a line is not a real setting we
            # can attribute to a section.
            /\\n/ { next }
            # Require the disabled setting to start at line beginning (after whitespace)
            # so we never match an "enabled = false" substring that happens to sit
            # inside a longer text or comment payload on the same line.
            /^[[:space:]]*(enabled|collect_basic_metrics)[[:space:]]*=[[:space:]]*false/ {
                line = $0
                gsub(/^[[:space:]]+/, "", line)
                print section "\t" line
            }
        ' "$cm_file" 2>/dev/null)

        # Namespace filtering. The upstream default ConfigMap excludes kube-system and
        # gatekeeper-system from stdout/stderr collection. Only WARN when filtering
        # deviates from those defaults (extra excluded namespaces, or any include_namespaces
        # allow-list which is uncommon). Otherwise surface as INFO so the operator can see
        # the filter is active without being told it's a problem.
        if grep -qiE "exclude_namespaces|include_namespaces" "$cm_file" 2>/dev/null; then
            local ns_lines ns_unusual=0
            ns_lines=$(grep -iE "exclude_namespaces|include_namespaces" "$cm_file" | head -10 | sed 's/^[[:space:]]*//')
            echo "$ns_lines" | grep -qiE "include_namespaces" && ns_unusual=1
            while IFS= read -r ns_line; do
                echo "$ns_line" | grep -qiE "exclude_namespaces" || continue
                local extras
                extras=$(echo "$ns_line" | grep -oE '\[[^]]*\]' | tr -d '[]"' | tr ',' '\n' \
                    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
                    | grep -viE '^(kube-system|gatekeeper-system)?$' | head -1)
                [[ -n "$extras" ]] && ns_unusual=1
            done <<< "$ns_lines"

            if [[ "$ns_unusual" -eq 1 ]]; then
                echo -e "  ${Yellow}[WARN] Namespace filtering deviates from upstream defaults:${NC}" | tee -a "$analysis_log"
                echo "$ns_lines" | sed 's/^/    /' | tee -a "$analysis_log"
                echo -e "         Verify this is not excluding namespaces that are expected to be collected." | tee -a "$analysis_log"
                ANALYSIS_FINDINGS+=("ConfigMap: namespace filtering deviates from upstream defaults. Verify expected namespaces are not excluded.")
                ((cm_issues++)); found_any=true
            else
                echo -e "  ${Cyan}[INFO] Namespace filtering matches upstream defaults (kube-system + gatekeeper-system excluded from stdout/stderr).${NC}" | tee -a "$analysis_log"
            fi
        fi

        # Surface the active ContainerLog schema version from the ConfigMap and, if the
        # Azure-side check ran, automatically reconcile against the DCR's enableContainerLogV2
        # setting. A mismatch is one of the most common "no data in the table I'm querying"
        # complaints — the agent is writing to one table, the customer is querying the other.
        local cm_schema
        cm_schema=$(grep -oE 'containerlog_schema_version\s*=\s*"?v[12]"?' "$cm_file" 2>/dev/null | head -1 | grep -oE 'v[12]')
        if [[ -n "$cm_schema" ]]; then
            if [[ -n "$DETECTED_DCR_CLV2" && "$DETECTED_DCR_CLV2" != "not set" ]]; then
                local expected_clv2="false"
                [[ "$cm_schema" == "v2" ]] && expected_clv2="true"
                local dcr_schema_label
                [[ "$DETECTED_DCR_CLV2" == "true" ]] && dcr_schema_label="v2" || dcr_schema_label="v1"
                if [[ "$DETECTED_DCR_CLV2" == "$expected_clv2" ]]; then
                    echo -e "  ${Green}[OK] ContainerLog schema is consistent: ConfigMap=${cm_schema}, DCR enableContainerLogV2=${DETECTED_DCR_CLV2} (${dcr_schema_label}).${NC}" | tee -a "$analysis_log"
                else
                    echo -e "  ${Red}[ISSUE] ContainerLog schema mismatch — agent writes to ${cm_schema}, DCR is configured for ${dcr_schema_label}.${NC}" | tee -a "$analysis_log"
                    echo -e "          ConfigMap containerlog_schema_version:  ${cm_schema}" | tee -a "$analysis_log"
                    echo -e "          DCR enableContainerLogV2:               ${DETECTED_DCR_CLV2} (${dcr_schema_label})" | tee -a "$analysis_log"
                    echo -e "          Logs are written to one table but the customer is querying the other. Reconcile" | tee -a "$analysis_log"
                    echo -e "          either the ConfigMap or the DCR so both target the same schema." | tee -a "$analysis_log"
                    ANALYSIS_FINDINGS+=("ContainerLog schema mismatch: ConfigMap=${cm_schema}, DCR enableContainerLogV2=${DETECTED_DCR_CLV2} (${dcr_schema_label}). Reconcile to avoid querying the wrong table.")
                    found_any=true
                fi
            else
                echo -e "  ${Cyan}[INFO] ConfigMap containerlog_schema_version: ${cm_schema}${NC}" | tee -a "$analysis_log"
                echo -e "         (Pass --cluster-resource-id to auto-compare against the DCR's enableContainerLogV2 setting." | tee -a "$analysis_log"
                echo -e "          A mismatch sends logs to a table the customer isn't querying.)" | tee -a "$analysis_log"
            fi
        fi

        if [[ "$cm_issues" -eq 0 ]]; then
            echo -e "  ${Green}[OK] No collection-disabling settings detected in ConfigMap${NC}" | tee -a "$analysis_log"
        fi
    fi

    # ── ama-logs events ──────────────────────────────────────────────────────
    # Scan the events file collected in other_logCollection for known bad-event patterns.
    # Catches things the per-pod describe doesn't surface: scheduling failures (no node
    # could host the pod), image pull failures (MCR mirror or NSG outbound block), Helm
    # rollout warnings (managed addon stuck mid-upgrade), and mount failures (missing CM
    # or secret). An empty file means nothing to flag — common on healthy clusters.
    local events_file="cluster/ama-logs-events.txt"
    if [[ -s "$events_file" ]]; then
        echo -e "\nAnalyzing ${events_file} for scheduling, image pull, and addon rollout issues..." | tee -a "$analysis_log"
        local event_issues=0

        if grep -qiE "FailedScheduling" "$events_file"; then
            local sched_line
            sched_line=$(grep -iE "FailedScheduling" "$events_file" | tail -1)
            echo -e "  ${Red}[ISSUE] FailedScheduling event present — at least one ama-logs pod cannot be scheduled.${NC}" | tee -a "$analysis_log"
            echo -e "          ${sched_line}" | tee -a "$analysis_log"
            echo -e "          Usually means node taints/tolerations or node selectors are mismatched, or the" | tee -a "$analysis_log"
            echo -e "          cluster has no Linux nodes available for the DaemonSet to land on." | tee -a "$analysis_log"
            ANALYSIS_FINDINGS+=("FailedScheduling for ama-logs pod(s). Review node taints, tolerations, and selectors. Sample event: ${sched_line}")
            ((event_issues++)); found_any=true
        fi

        if grep -qiE "ImagePullBackOff|ErrImagePull" "$events_file"; then
            local pull_line
            pull_line=$(grep -iE "ImagePullBackOff|ErrImagePull" "$events_file" | tail -1)
            echo -e "  ${Red}[ISSUE] Image pull failure — agent image cannot be pulled from MCR.${NC}" | tee -a "$analysis_log"
            echo -e "          ${pull_line}" | tee -a "$analysis_log"
            echo -e "          Confirm outbound HTTPS to mcr.microsoft.com is allowed, or use an MCR mirror" | tee -a "$analysis_log"
            echo -e "          if the cluster is air-gapped." | tee -a "$analysis_log"
            ANALYSIS_FINDINGS+=("Image pull failure for ama-logs. Confirm outbound to mcr.microsoft.com is open. Sample event: ${pull_line}")
            ((event_issues++)); found_any=true
        fi

        if grep -qiE "FailedMount" "$events_file"; then
            local mount_line
            mount_line=$(grep -iE "FailedMount" "$events_file" | tail -1)
            echo -e "  ${Red}[ISSUE] Volume mount failure on an ama-logs pod:${NC}" | tee -a "$analysis_log"
            echo -e "          ${mount_line}" | tee -a "$analysis_log"
            echo -e "          Usually the ama-logs-secret or container-azm-ms-agentconfig ConfigMap is missing." | tee -a "$analysis_log"
            ANALYSIS_FINDINGS+=("FailedMount on ama-logs pod — likely missing Secret or ConfigMap. Sample event: ${mount_line}")
            ((event_issues++)); found_any=true
        fi

        if grep -qiE "BackOff" "$events_file" && ! grep -qiE "ImagePullBackOff" "$events_file"; then
            local backoff_line
            backoff_line=$(grep -iE "BackOff" "$events_file" | grep -viE "ImagePullBackOff" | tail -1)
            if [[ -n "$backoff_line" ]]; then
                echo -e "  ${Yellow}[WARN] CrashLoopBackOff or similar BackOff event on ama-logs:${NC}" | tee -a "$analysis_log"
                echo -e "         ${backoff_line}" | tee -a "$analysis_log"
                echo -e "         Inspect logs_*_previous.txt for the crash reason." | tee -a "$analysis_log"
                ANALYSIS_FINDINGS+=("BackOff event on ama-logs pod. Inspect logs_*_previous.txt for the crash reason. Sample event: ${backoff_line}")
                ((event_issues++)); found_any=true
            fi
        fi

        if [[ "$event_issues" -eq 0 ]]; then
            echo -e "  ${Green}[OK] No scheduling, image pull, or mount failures found in collected events.${NC}" | tee -a "$analysis_log"
        fi
    fi

    # ── DaemonSet desired vs ready/available ──────────────────────────────────
    # `kubectl get daemonset` prints DESIRED CURRENT READY UP-TO-DATE AVAILABLE …
    # When desired != ready (or != available), pods aren't landing on every node —
    # usually node taints, scheduling failures, or image pull issues. This catches
    # cases where SOME nodes are missing the agent (vs the per-pod describe analysis
    # which only looks at pods that DID schedule).
    local ds_status="cluster/daemonset-status.txt"
    if [[ -s "$ds_status" ]]; then
        echo -e "\nAnalyzing ${ds_status} for DaemonSet rollout coverage..." | tee -a "$analysis_log"
        local ds_name ds_desired ds_current ds_ready ds_uptodate ds_available
        while read -r ds_name ds_desired ds_current ds_ready ds_uptodate ds_available _; do
            [[ -z "$ds_name" || "$ds_name" == "NAME" ]] && continue
            [[ "$ds_desired" =~ ^[0-9]+$ ]] || continue
            if [[ "$ds_desired" != "$ds_ready" || "$ds_desired" != "$ds_available" ]]; then
                echo -e "  ${Red}[ISSUE] DaemonSet ${ds_name}: desired=${ds_desired}, ready=${ds_ready}, available=${ds_available}.${NC}" | tee -a "$analysis_log"
                echo -e "          $((ds_desired - ds_ready)) pod(s) not ready, $((ds_desired - ds_available)) pod(s) not available." | tee -a "$analysis_log"
                echo -e "          Check 'kubectl get pods -n kube-system | grep ${ds_name}' — common causes:" | tee -a "$analysis_log"
                echo -e "          node taints without matching tolerations, FailedScheduling, image pull failures, or volume mount errors." | tee -a "$analysis_log"
                ANALYSIS_FINDINGS+=("DaemonSet ${ds_name} not fully rolled out (desired=${ds_desired}, ready=${ds_ready}, available=${ds_available}). Some nodes have no agent.")
                found_any=true
            else
                echo -e "  ${Green}[OK] DaemonSet ${ds_name}: ${ds_desired}/${ds_desired} pods desired/ready/available.${NC}" | tee -a "$analysis_log"
            fi
        done < "$ds_status"
    fi

    # ── ConfigMap mount sanity check (effective settings on disk) ─────────────
    # The agent mounts container-azm-ms-agentconfig at /etc/config/settings and the
    # entrypoint splits its contents into per-section files (one per top-level YAML
    # key — log-data-collection-settings, agent-settings, integrations, …). If the
    # folder is empty/missing the mount failed and the agent is running with built-in
    # defaults regardless of what the YAML in the cluster says — a silent
    # "my custom settings have no effect" failure mode.
    # Skip this entire block if the customer hasn't applied container-azm-ms-agentconfig
    # — the agent is running with built-in defaults and the kubelet has nothing to project,
    # so an empty settings folder is expected, not a finding.
    if [[ ! -f "cluster/container-azm-ms-agentconfig.yaml" ]]; then
        echo -e "\nVerifying effective agent settings under ama-logs-daemonset/settings/..." | tee -a "$analysis_log"
        echo -e "  ${Cyan}[INFO] container-azm-ms-agentconfig ConfigMap is not present on the cluster — agent is running with built-in defaults. Mount sanity check skipped.${NC}" | tee -a "$analysis_log"
    elif [[ -d "ama-logs-daemonset/settings" ]]; then
        echo -e "\nVerifying effective agent settings under ama-logs-daemonset/settings/..." | tee -a "$analysis_log"
        local settings_dir
        settings_dir=$(find ama-logs-daemonset/settings -mindepth 1 -maxdepth 1 -type d -name '..*' 2>/dev/null | sort -r | head -1)
        if [[ -z "$settings_dir" ]]; then
            echo -e "  ${Yellow}[WARN] No effective settings data folder found under ama-logs-daemonset/settings/.${NC}" | tee -a "$analysis_log"
            echo -e "         The ConfigMap exists on the cluster but kubelet did not project it into the pod" | tee -a "$analysis_log"
            echo -e "         (or kubectl cp did not capture it). Agent is running with built-in defaults in" | tee -a "$analysis_log"
            echo -e "         this case — any customization in the ConfigMap will not take effect." | tee -a "$analysis_log"
            ANALYSIS_FINDINGS+=("Effective agent settings folder is empty/missing — ConfigMap mount may have failed; agent likely running with built-in defaults.")
            found_any=true
        else
            local settings_count
            settings_count=$(find "$settings_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
            settings_count="${settings_count//[[:space:]]/}"
            if [[ "${settings_count:-0}" -lt 3 ]]; then
                echo -e "  ${Yellow}[WARN] Effective settings folder ${settings_dir} has only ${settings_count} file(s) — partial mount?${NC}" | tee -a "$analysis_log"
                echo -e "         Expect at least log-data-collection-settings, agent-settings, integrations, and metric_collection_settings." | tee -a "$analysis_log"
                ANALYSIS_FINDINGS+=("Effective agent settings folder ${settings_dir} has only ${settings_count} file(s); ConfigMap mount may be incomplete.")
                found_any=true
            else
                echo -e "  ${Green}[OK] ConfigMap mount delivered ${settings_count} effective settings file(s) at ${settings_dir}.${NC}" | tee -a "$analysis_log"
                local mounted_schema mounted_cfg
                [[ -f "$settings_dir/schema-version" ]] && mounted_schema=$(tr -d '\r\n' < "$settings_dir/schema-version")
                [[ -f "$settings_dir/config-version" ]] && mounted_cfg=$(tr -d '\r\n' < "$settings_dir/config-version")
                [[ -n "$mounted_schema" || -n "$mounted_cfg" ]] && \
                    echo -e "         Mounted schema-version=${mounted_schema:-(empty)}, config-version=${mounted_cfg:-(empty)}." | tee -a "$analysis_log"
            fi
        fi
    fi

    # ── fluentd (cluster-level and DS) ────────────────────────────────────────
    for fluentd in ama-logs-daemonset/fluentd.log ama-logs-replicaset/fluentd.log; do
        [[ ! -f "$fluentd" ]] && continue
        echo -e "\nChecking ${fluentd} — the routing layer that forwards data through the pipeline..." | tee -a "$analysis_log"
        if scan_log "$fluentd" "$fluentd" \
            "error|exception|401|403|failed" \
            "Errors detected in Fluentd log." \
            "Review the full file for auth failures or collection errors. 401/403 errors indicate an MSI token issue."; then
            found_any=true
        else
            echo -e "  ${Green}[OK] No errors in fluentd — data routing layer is operating normally.${NC}" | tee -a "$analysis_log"
        fi
    done

    # ── Summary ───────────────────────────────────────────────────────────────
    echo -e "" | tee -a "$analysis_log"
    if [[ ${#ANALYSIS_FINDINGS[@]} -eq 0 ]]; then
        echo -e "${Green}${Bold}[ANALYSIS SUMMARY] No issues automatically detected in the collected logs.${NC}" | tee -a "$analysis_log" Tool.log
        echo -e "${Cyan}  The agent pipeline appears healthy. If data is still missing from the workspace, consider:${NC}" | tee -a "$analysis_log"
        echo -e "${Cyan}  - Reviewing the Azure configuration check results (if --cluster-resource-id was provided)${NC}" | tee -a "$analysis_log"
        echo -e "${Cyan}  - Checking whether a daily ingestion cap has been hit on the Log Analytics workspace${NC}" | tee -a "$analysis_log"
        echo -e "${Cyan}  - Providing the full archive to Azure Monitor support for deeper analysis${NC}" | tee -a "$analysis_log"
    else
        echo -e "${Red}${Bold}[ANALYSIS SUMMARY] ${#ANALYSIS_FINDINGS[@]} issue(s) detected:${NC}" | tee -a "$analysis_log" Tool.log
        for i in "${!ANALYSIS_FINDINGS[@]}"; do
            echo -e "  $((i+1)). ${ANALYSIS_FINDINGS[$i]}" | tee -a "$analysis_log" Tool.log
        done
    fi

    echo -e "\nFull analysis saved to ${analysis_log}" | tee -a Tool.log
}

# ─── _check_dcr_dcra ──────────────────────────────────────────────────────────
# Called from azure_config_check when MSI auth mode is confirmed.
# Finds the Container Insights DCR associated with the cluster, validates its
# structure, and updates WORKSPACE_ID from the DCR destination if not yet set.
_check_dcr_dcra() {
    local az_log="$1"

    echo -e "\n${Bold}Data Collection Rule (DCR) / Association Check:${NC}" | tee -a "$az_log"
    echo -e "The DCR tells the agent what data to collect, which tables to write to, and which workspace to target." | tee -a "$az_log"

    local dcra_json
    dcra_json=$(az monitor data-collection rule association list \
        --resource "$CLUSTER_RESOURCE_ID" -o json 2>/dev/null)

    if [[ -z "$dcra_json" ]] || [[ "$dcra_json" == "[]" ]]; then
        echo -e "  ${Red}[ERROR] No Data Collection Rule associations found for this cluster.${NC}" | tee -a "$az_log"
        echo -e "          The agent requires a DCR to know what data to collect and where to send it." | tee -a "$az_log"
        echo -e "          Without a DCR association, the agent will not collect any data." | tee -a "$az_log"
        echo -e "          Enable Container Insights via the Azure Portal (Monitoring > Insights) to create the DCR automatically." | tee -a "$az_log"
        ANALYSIS_FINDINGS+=("No DCR associations found on the cluster. A DCR with a ContainerInsights data source must be associated with the cluster resource.")
        return
    fi

    local dcr_ids
    dcr_ids=$(echo "$dcra_json" | python3 -c "
import sys, json
for item in json.load(sys.stdin):
    dcr = item.get('dataCollectionRuleId','')
    if dcr: print(dcr)
" 2>/dev/null)

    local ci_dcr_found=false
    for dcr_id in $dcr_ids; do
        local dcr_json
        dcr_json=$(az monitor data-collection rule show --ids "$dcr_id" -o json 2>/dev/null)
        [[ -z "$dcr_json" ]] && continue

        local is_ci
        is_ci=$(echo "$dcr_json" | python3 -c "
import sys, json
exts = json.load(sys.stdin).get('dataSources',{}).get('extensions',[])
print('yes' if any(e.get('extensionName')=='ContainerInsights' for e in exts) else 'no')
" 2>/dev/null)
        [[ "$is_ci" != "yes" ]] && continue

        ci_dcr_found=true

        # Extract all relevant fields in one Python call to avoid re-parsing
        local fields
        fields=$(echo "$dcr_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
exts  = d.get('dataSources',{}).get('extensions',[])
ci    = next((e for e in exts if e.get('extensionName')=='ContainerInsights'), {})
sets  = ci.get('extensionSettings',{}).get('dataCollectionSettings',{})
dests = d.get('destinations',{}).get('logAnalytics',[])
dest  = dests[0] if dests else {}
print('|'.join([
    d.get('name',''),
    dest.get('workspaceId',''),
    dest.get('workspaceResourceId',''),
    ', '.join(ci.get('streams',[])),
    sets.get('interval','not set'),
    sets.get('namespaceFilteringMode','not set'),
    str(sets.get('enableContainerLogV2','not set')),
    d.get('dataCollectionEndpointId',''),
]))
" 2>/dev/null)

        local dcr_name ws_id ws_resource_id streams interval ns_filter clv2 dce_id
        IFS='|' read -r dcr_name ws_id ws_resource_id streams interval ns_filter clv2 dce_id <<< "$fields"
        # Python's str(bool) emits "True"/"False"; normalize to lowercase so downstream
        # comparisons ([[ "$clv2" == "true" ]] and the cross-check) work as expected.
        clv2=$(echo "$clv2" | tr '[:upper:]' '[:lower:]')

        echo -e "  ${Green}[OK] Container Insights DCR found: ${dcr_name}${NC}" | tee -a "$az_log"
        echo -e "  Destination workspace:     ${ws_id:-not found}"    | tee -a "$az_log"
        echo -e "  Configured data streams:   ${streams:-not found}"   | tee -a "$az_log"
        echo -e "  Collection interval:       ${interval} (how often the agent collects metrics/inventory)"  | tee -a "$az_log"
        echo -e "  Namespace filtering mode:  ${ns_filter}"            | tee -a "$az_log"
        if [[ "$clv2" == "true" ]]; then
            echo -e "  ContainerLogV2 enabled:    yes (container logs stored in ContainerLogV2 table — structured format)"  | tee -a "$az_log"
        elif [[ "$clv2" == "false" ]]; then
            echo -e "  ContainerLogV2 enabled:    no (container logs stored in ContainerLog table — legacy format)"  | tee -a "$az_log"
        else
            echo -e "  ContainerLogV2 enabled:    ${clv2}"             | tee -a "$az_log"
        fi
        # Persist the DCR's ContainerLogV2 setting so the post-collection analyzer
        # can cross-check it against the agent's ConfigMap containerlog_schema_version.
        DETECTED_DCR_CLV2="$clv2"
        if [[ -n "$dce_id" ]]; then
            local dce_name
            dce_name=$(az monitor data-collection endpoint show --ids "$dce_id" --query "name" -o tsv 2>/dev/null)
            echo -e "  Data Collection Endpoint:  ${dce_name:-$dce_id}" | tee -a "$az_log"
            DETECTED_DCE_ID="$dce_id"
        else
            if $USE_AMPLS; then
                echo -e "  Data Collection Endpoint:  (not configured in DCR — see DCE AMPLS check below)" | tee -a "$az_log"
            else
                echo -e "  Data Collection Endpoint:  (none — agent uses default regional endpoint)" | tee -a "$az_log"
            fi
        fi

        # Populate global WORKSPACE_ID from DCR if not already known
        if [[ -z "$WORKSPACE_ID" ]] && [[ -n "$ws_id" ]]; then
            WORKSPACE_ID="$ws_id"
            echo -e "  ${Cyan}[INFO] Workspace ID set from DCR destination: ${WORKSPACE_ID}${NC}" | tee -a "$az_log"
        fi

        # Warn if the DCR destination does not match the workspace we detected
        if [[ -n "$WORKSPACE_ID" ]] && [[ -n "$ws_id" ]] && [[ "$WORKSPACE_ID" != "$ws_id" ]]; then
            echo -e "  ${Red}[ISSUE] Workspace ID mismatch: DCR is sending to ${ws_id} but detected workspace is ${WORKSPACE_ID}.${NC}" | tee -a "$az_log"
            echo -e "          Data may be flowing to the wrong workspace." | tee -a "$az_log"
            ANALYSIS_FINDINGS+=("DCR workspace mismatch: DCR destination is ${ws_id} but the detected workspace ID is ${WORKSPACE_ID}. Data may be flowing to the wrong workspace.")
        fi

        if [[ "$ns_filter" == "Include" ]] || [[ "$ns_filter" == "Exclude" ]]; then
            echo -e "  ${Yellow}[WARN] Namespace filtering is active (mode: ${ns_filter})." | tee -a "$az_log"
            echo -e "         Only namespaces matching the filter will have their container logs collected." | tee -a "$az_log"
            echo -e "         If logs from a specific namespace are missing, verify it is covered by this filter." | tee -a "$az_log"
            echo -e "         To review the full filter configuration: az monitor data-collection rule show --ids ${dcr_id}${NC}" | tee -a "$az_log"
            ANALYSIS_FINDINGS+=("DCR namespace filtering is set to '${ns_filter}'. Verify this is not excluding namespaces the customer expects to collect.")
        fi

        # ── DataFlows validation: every declared stream should be routed to a Log Analytics destination
        local orphan_streams
        orphan_streams=$(echo "$dcr_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
exts = d.get('dataSources',{}).get('extensions',[])
ci = next((e for e in exts if e.get('extensionName')=='ContainerInsights'), {})
declared = set(ci.get('streams',[]))
la_dests = {dst.get('name') for dst in d.get('destinations',{}).get('logAnalytics',[]) if dst.get('name')}
routed = set()
for f in d.get('dataFlows',[]):
    if set(f.get('destinations',[])) & la_dests:
        routed |= set(f.get('streams',[])) & declared
orphan = sorted(declared - routed)
print(','.join(orphan))
" 2>/dev/null)

        if [[ -n "$orphan_streams" ]]; then
            echo -e "  ${Red}[ISSUE] DCR has streams declared on the ContainerInsights data source that are NOT routed" | tee -a "$az_log"
            echo -e "          to a Log Analytics destination via dataFlows: ${orphan_streams}${NC}" | tee -a "$az_log"
            echo -e "          Data for these streams will be collected by the agent but silently dropped at the pipeline" | tee -a "$az_log"
            echo -e "          because no dataFlow entry routes them to a workspace destination." | tee -a "$az_log"
            echo -e "          -> Edit the DCR to add a dataFlow entry mapping each missing stream to the logAnalytics destination." | tee -a "$az_log"
            ANALYSIS_FINDINGS+=("DCR dataFlows: streams [${orphan_streams}] are declared on the ContainerInsights data source but not routed to a Log Analytics destination. These streams will be silently dropped — add matching dataFlow entries.")
        else
            echo -e "  ${Green}[OK] All declared CI streams are routed to a Log Analytics destination via dataFlows.${NC}" | tee -a "$az_log"
        fi

        break  # Only process the first Container Insights DCR found
    done

    if ! $ci_dcr_found; then
        echo -e "  ${Red}[ERROR] No Container Insights DCR found in the rules associated with this cluster.${NC}" | tee -a "$az_log"
        echo -e "          The cluster has a DCR association, but none of the associated DCRs contain a" | tee -a "$az_log"
        echo -e "          ContainerInsights data source. Without this, the agent does not know what to collect." | tee -a "$az_log"
        echo -e "          Re-enable Container Insights via the Azure Portal to recreate the correct DCR." | tee -a "$az_log"
        ANALYSIS_FINDINGS+=("No Container Insights DCR found in cluster associations. A DCR with a ContainerInsights data source must be associated with the cluster.")
    fi
}

# ─── _check_daily_cap ─────────────────────────────────────────────────────────
_check_daily_cap() {
    local az_log="$1"

    echo -e "\n${Bold}Daily Ingestion Cap Check:${NC}" | tee -a "$az_log"
    echo -e "A daily cap limits the total data the workspace accepts each day. Once hit, ingestion is suspended" | tee -a "$az_log"
    echo -e "until the next UTC midnight reset — causing data gaps that can look like an agent outage." | tee -a "$az_log"

    if [[ -z "$WORKSPACE_ID" ]]; then
        echo -e "  ${Yellow}[SKIP] Workspace ID not available - pass --workspace-id or --cluster-resource-id to enable this check.${NC}" | tee -a "$az_log"
        return
    fi

    local cap_result
    cap_result=$(az monitor log-analytics query \
        --workspace "$WORKSPACE_ID" \
        --analytics-query "_LogOperation | where TimeGenerated >= ago(7d) | where Category == 'Ingestion' | where Detail has 'OverQuota' | project TimeGenerated, Category, Detail" \
        -o json 2>/dev/null)

    if [[ -z "$cap_result" ]] || [[ "$cap_result" == "null" ]]; then
        echo -e "  ${Yellow}[WARN] Daily cap query could not be executed. This is typically due to insufficient" | tee -a "$az_log"
        echo -e "         permissions on the Log Analytics workspace. Continuing with remaining checks.${NC}" | tee -a "$az_log"
        return
    fi

    local cap_output
    cap_output=$(echo "$cap_result" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    rows = []
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict) and 'TimeGenerated' in item:
                rows.append(item)
            elif isinstance(item, dict) and 'tables' in item:
                for t in item.get('tables', []):
                    cols = [c['name'] for c in t.get('columns', [])]
                    for r in t.get('rows', []):
                        rows.append(dict(zip(cols, r)))
    if not rows:
        print('NO_DATA')
        sys.exit(0)
    for r in rows:
        ts = str(r.get('TimeGenerated', '')).replace('T', ' ').split('.')[0]
        detail = str(r.get('Detail', ''))
        print(f'  {ts}  {detail}')
except Exception as e:
    print(f'PARSE_ERROR: {e}')
" 2>/dev/null)

    if [[ "$cap_output" == "NO_DATA" ]]; then
        echo -e "  ${Green}[OK] Daily ingestion cap has not been triggered in the last 7 days.${NC}" | tee -a "$az_log"
        echo -e "       Data ingestion has not been interrupted by a workspace cap limit." | tee -a "$az_log"
    elif [[ "$cap_output" == PARSE_ERROR* ]]; then
        echo -e "  ${Yellow}[WARN] Daily cap query returned data but could not be parsed. Raw result saved to ${az_log}.${NC}" | tee -a "$az_log"
        echo "$cap_result" >> "$az_log"
    else
        echo -e "  ${Red}[ISSUE] Daily ingestion cap was triggered in the last 7 days:${NC}" | tee -a "$az_log"
        echo -e "$cap_output" | tee -a "$az_log"
        echo -e "          Data is dropped once the cap is hit each day until the next UTC midnight reset." | tee -a "$az_log"
        echo -e "          -> Raise or remove the daily cap: Azure Portal > Log Analytics workspace >" | tee -a "$az_log"
        echo -e "             Usage and estimated costs > Daily cap.${NC}" | tee -a "$az_log"
        ANALYSIS_FINDINGS+=("Daily ingestion cap triggered in the last 7 days. Data is dropped once the cap is hit each day. Raise or remove the daily cap in the workspace Usage and estimated costs settings.")
    fi
}

# ─── _check_workspace_tables ─────────────────────────────────────────────────
# Queries the workspace for Container Insights table activity in the last hour.
# Results are informational only — not all tables are expected to have constant
# writes, and DCR-based clusters only collect the streams they are configured for.
_check_workspace_tables() {
    local az_log="$1" use_aad_auth="$2"

    echo -e "\n${Bold}Recent Table Activity in Workspace (last 1 hour):${NC}" | tee -a "$az_log"
    echo -e "Shows which Container Insights tables have received data in the last hour." | tee -a "$az_log"
    echo -e "Not all tables write continuously — Perf, Events, and Inventory tables update on their collection interval." | tee -a "$az_log"

    if [[ -z "$WORKSPACE_ID" ]]; then
        echo -e "  ${Yellow}[SKIP] Workspace ID not available.${NC}" | tee -a "$az_log"
        return
    fi

    if [[ "$use_aad_auth" == "true" ]]; then
        echo -e "  ${Cyan}[INFO] This cluster uses MSI/DCR mode — only data streams configured in the DCR are expected to appear here.${NC}" | tee -a "$az_log"
        echo -e "         Tables not covered by the DCR will show no rows even when the agent is healthy." | tee -a "$az_log"
    fi

    local query='union isfuzzy=true ContainerLog, ContainerLogV2, KubePodInventory, KubeNodeInventory, KubeEvents, KubeServices, KubeMonAgentEvents, InsightsMetrics, ContainerInventory, ContainerServiceLog, ContainerNodeInventory, Perf | where TimeGenerated >= ago(1h) | summarize LastIngest=max(TimeGenerated), Rows=count() by Type | order by Type asc'

    local result
    result=$(az monitor log-analytics query \
        --workspace "$WORKSPACE_ID" \
        --analytics-query "$query" \
        -o json 2>/dev/null)

    if [[ -z "$result" ]] || [[ "$result" == "null" ]]; then
        echo -e "  ${Yellow}[WARN] Table activity query could not be executed (insufficient permissions or workspace unreachable). Continuing.${NC}" | tee -a "$az_log"
        return
    fi

    local table_output
    table_output=$(echo "$result" | python3 -c "
import sys, json
from datetime import datetime, timezone
try:
    data = json.load(sys.stdin)
    rows = []
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict) and 'Type' in item:
                rows.append(item)
            elif isinstance(item, dict) and 'tables' in item:
                for t in item.get('tables', []):
                    cols = [c['name'] for c in t.get('columns', [])]
                    for r in t.get('rows', []):
                        rows.append(dict(zip(cols, r)))
    if not rows:
        print('NO_DATA')
        sys.exit(0)
    print(f'  {\"Table\":<35} {\"Rows\":>8}  Last Ingest')
    print('  ' + '-' * 65)
    last_times = []
    for r in rows:
        table = r.get('Type', '')
        count = r.get('Rows', r.get('count_', 0))
        last  = str(r.get('LastIngest', r.get('max_TimeGenerated', ''))).replace('T', ' ').split('.')[0]
        print(f'  {table:<35} {str(count):>8}  {last}')
        try:
            last_times.append(datetime.strptime(last, '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc))
        except:
            pass
    # Emit a machine-readable stale-cutoff marker if all tables stopped at roughly the
    # same time more than 15 minutes ago — a strong indicator of a daily cap event.
    if len(last_times) >= 2:
        most_recent = max(last_times)
        spread = (most_recent - min(last_times)).total_seconds()
        gap = (datetime.now(timezone.utc) - most_recent).total_seconds()
        if gap > 900 and spread < 120:
            print(f'STALE_CUTOFF {most_recent.strftime(\"%Y-%m-%d %H:%M:%S\")} {int(gap // 60)}')
except Exception as e:
    print(f'PARSE_ERROR: {e}')
" 2>/dev/null)

    if [[ "$table_output" == "NO_DATA" ]]; then
        echo -e "  ${Cyan}[INFO] No Container Insights tables had data ingested in the last hour.${NC}" | tee -a "$az_log"
        echo -e "         This does not necessarily mean collection is broken — the agent may be healthy but" | tee -a "$az_log"
        echo -e "         no data has been generated in that window (e.g. no container activity, low collection interval)." | tee -a "$az_log"
        echo -e "         Check mdsd.qos in the archive to confirm whether the agent is transmitting rows." | tee -a "$az_log"
    elif [[ "$table_output" == PARSE_ERROR* ]]; then
        echo -e "  ${Yellow}[WARN] Could not parse table activity results.${NC}" | tee -a "$az_log"
    else
        local stale_line display_output
        stale_line=$(echo "$table_output" | grep "^STALE_CUTOFF" || true)
        display_output=$(echo "$table_output" | grep -v "^STALE_CUTOFF")
        echo "$display_output" | tee -a "$az_log"
        if [[ -n "$stale_line" ]]; then
            local cutoff_time cutoff_mins
            cutoff_time=$(echo "$stale_line" | awk '{print $2, $3}')
            cutoff_mins=$(echo "$stale_line" | awk '{print $4}')
            echo -e "  ${Yellow}[WARN] All tables stopped ingesting at the same time (~${cutoff_time} UTC, ${cutoff_mins} min ago)." | tee -a "$az_log"
            echo -e "         A simultaneous cutoff across all tables is a strong indicator of a daily ingestion cap or networking change." | tee -a "$az_log"
            echo -e "         Cross-reference with the Daily Ingestion Cap Check or network connectivity checks.${NC}" | tee -a "$az_log"
        fi
    fi
}

# ─── _check_workspace_network_isolation ──────────────────────────────────────
# Checks publicNetworkAccessForIngestion on the workspace and, when AMPLS is
# detected, verifies the workspace is a connected resource in a private link scope.
_check_workspace_network_isolation() {
    local az_log="$1"

    echo -e "\n${Bold}Log Analytics Workspace Network Isolation:${NC}" | tee -a "$az_log"
    echo -e "Verifies whether the workspace accepts public ingestion, and if AMPLS is in use," | tee -a "$az_log"
    echo -e "whether the workspace is linked as a connected resource in the private link scope." | tee -a "$az_log"

    if [[ -z "$WORKSPACE_ID" ]]; then
        echo -e "  ${Yellow}[SKIP] Workspace ID not available - pass --workspace-id or --cluster-resource-id to enable this check.${NC}" | tee -a "$az_log"
        return
    fi

    local ws_json
    ws_json=$(az monitor log-analytics workspace list \
        --query "[?customerId=='${WORKSPACE_ID}'] | [0]" -o json 2>/dev/null)

    if [[ -z "$ws_json" ]] || [[ "$ws_json" == "null" ]]; then
        echo -e "  ${Yellow}[WARN] Could not locate workspace with ID ${WORKSPACE_ID} in the current subscription." | tee -a "$az_log"
        echo -e "         The workspace may be in a different subscription. Skipping this check.${NC}" | tee -a "$az_log"
        return
    fi

    local ws_name ws_rg ws_resource_id public_ingestion
    ws_name=$(echo "$ws_json"          | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null)
    ws_rg=$(echo "$ws_json"            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('resourceGroup',''))" 2>/dev/null)
    ws_resource_id=$(echo "$ws_json"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null)
    public_ingestion=$(echo "$ws_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('publicNetworkAccessForIngestion',''))" 2>/dev/null)

    if [[ -z "$public_ingestion" ]]; then
        echo -e "  ${Yellow}[WARN] Could not read publicNetworkAccessForIngestion from workspace response.${NC}" | tee -a "$az_log"
        return
    fi

    echo -e "  Workspace: ${ws_name} (resource group: ${ws_rg})" | tee -a "$az_log"

    if [[ "$public_ingestion" == "Disabled" ]]; then
        if ! $USE_AMPLS; then
            echo -e "  ${Red}[ISSUE] Workspace '${ws_name}' requires private network ingestion" | tee -a "$az_log"
            echo -e "          (publicNetworkAccessForIngestion = Disabled) but the cluster does not appear to be" | tee -a "$az_log"
            echo -e "          using AMPLS. Data sent over public endpoints will be rejected by the workspace.${NC}" | tee -a "$az_log"
            echo -e "          -> Either enable public network access on the workspace, or configure an Azure" | tee -a "$az_log"
            echo -e "             Monitor Private Link Scope (AMPLS) and connect this cluster's private endpoint to it." | tee -a "$az_log"
            ANALYSIS_FINDINGS+=("Workspace ${ws_name}: publicNetworkAccessForIngestion=Disabled but cluster is not using AMPLS. Ingestion over public endpoints will be rejected.")
        else
            echo -e "  ${Green}[OK] Workspace requires private network ingestion and cluster is using AMPLS — consistent configuration.${NC}" | tee -a "$az_log"
        fi
    else
        echo -e "  ${Green}[OK] Workspace accepts ingestion from public networks (publicNetworkAccessForIngestion = ${public_ingestion}).${NC}" | tee -a "$az_log"
    fi

    # When AMPLS is in use, verify the workspace is a connected resource in a scope
    if $USE_AMPLS; then
        echo -e "\n  Checking whether workspace is a connected resource in an AMPLS scope..." | tee -a "$az_log"

        local scopes_json
        scopes_json=$(az monitor private-link-scope list -o json 2>/dev/null)

        if [[ -z "$scopes_json" ]] || [[ "$scopes_json" == "[]" ]]; then
            echo -e "  ${Yellow}[WARN] No Azure Monitor Private Link Scopes found in this subscription." | tee -a "$az_log"
            echo -e "         AMPLS is detected but no scopes exist here — the scope may be in a different subscription.${NC}" | tee -a "$az_log"
            return
        fi

        local scope_count found_in_scope=false scope_name_found="" scope_access_mode_found=""
        local private_only_scopes=()
        scope_count=$(echo "$scopes_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
        echo -e "  Found ${scope_count} AMPLS scope(s) in this subscription." | tee -a "$az_log"

        while IFS='|' read -r scope_name scope_rg scope_access_mode; do
            [[ "$scope_access_mode" == "PrivateOnly" ]] && private_only_scopes+=("${scope_name} (ingestion=PrivateOnly)")
            local scoped_resources
            scoped_resources=$(az monitor private-link-scope scoped-resource list \
                --scope-name "$scope_name" --resource-group "$scope_rg" -o json 2>/dev/null)
            if WS_RESOURCE_ID="$ws_resource_id" python3 -c "
import sys, json, os
ws_id = os.environ.get('WS_RESOURCE_ID','').lower()
found = any(r.get('linkedResourceId','').lower() == ws_id for r in json.load(sys.stdin))
sys.exit(0 if found else 1)
" <<< "$scoped_resources" 2>/dev/null; then
                found_in_scope=true
                scope_name_found="$scope_name"
                scope_access_mode_found="$scope_access_mode"
                break
            fi
        done < <(echo "$scopes_json" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    am = s.get('accessModeSettings') or s.get('properties',{}).get('accessModeSettings') or {}
    mode = am.get('ingestionAccessMode','Open')
    print(s['name'] + '|' + s['resourceGroup'] + '|' + mode)
" 2>/dev/null)

        if $found_in_scope; then
            echo -e "  ${Green}[OK] Workspace '${ws_name}' is a connected resource in AMPLS scope '${scope_name_found}' (ingestion access mode: ${scope_access_mode_found:-Open}).${NC}" | tee -a "$az_log"
            echo -e "       Data from this cluster can reach the workspace through the private link." | tee -a "$az_log"
        else
            echo -e "  ${Red}[ISSUE] Workspace '${ws_name}' is NOT a connected resource in any AMPLS scope in this subscription.${NC}" | tee -a "$az_log"
            echo -e "          The cluster routes through AMPLS but the workspace is not linked to the scope." | tee -a "$az_log"
            echo -e "          Data will be dropped when it reaches the private link endpoint.${NC}" | tee -a "$az_log"
            echo -e "          -> Add '${ws_name}' as a scoped resource in the AMPLS scope covering this cluster." | tee -a "$az_log"
            ANALYSIS_FINDINGS+=("AMPLS: Workspace '${ws_name}' is not a connected resource in any AMPLS scope in this subscription. Ingestion through the private link will fail.")
            if [[ ${#private_only_scopes[@]} -gt 0 ]]; then
                echo -e "  ${Red}          Additionally, the following scope(s) are configured PrivateOnly for ingestion:${NC}" | tee -a "$az_log"
                printf '            - %s\n' "${private_only_scopes[@]}" | tee -a "$az_log"
                echo -e "  ${Red}          Public-endpoint ingestion will be REJECTED by any of these scopes regardless of" | tee -a "$az_log"
                echo -e "          the workspace's own publicNetworkAccessForIngestion setting. This is a hard block.${NC}" | tee -a "$az_log"
                ANALYSIS_FINDINGS+=("AMPLS: PrivateOnly ingestion scope(s) [${private_only_scopes[*]}] exist in this subscription and the workspace is not linked to any AMPLS scope. Ingestion is hard-blocked.")
            fi
        fi
    fi
}

# ─── _check_dce_ampls ────────────────────────────────────────────────────────
# In AMPLS mode, verifies that a Data Collection Endpoint (DCE) is configured
# and is a connected resource in the AMPLS scope. The DCE is the endpoint the
# agent uses to fetch its DCR configuration; if it is not in the scope, config
# delivery fails over the private link (typically manifests as 403 errors in mdsd).
_check_dce_ampls() {
    local az_log="$1"

    echo -e "\n${Bold}Data Collection Endpoint (DCE) AMPLS Check:${NC}" | tee -a "$az_log"
    echo -e "In AMPLS mode, the DCE used for configuration delivery must be a connected resource" | tee -a "$az_log"
    echo -e "in the AMPLS scope, and must have an association with the cluster resource." | tee -a "$az_log"

    # ── Step 1: Find the DCE ID ───────────────────────────────────────────────
    # Prefer the DCE embedded in the DCR (set by _check_dcr_dcra); fall back to
    # a direct DataCollectionEndpointAssociation on the cluster resource.
    local dce_id="$DETECTED_DCE_ID" dce_source="DCR"

    if [[ -z "$dce_id" ]]; then
        local dcra_json
        dcra_json=$(az monitor data-collection rule association list \
            --resource "$CLUSTER_RESOURCE_ID" -o json 2>/dev/null)
        dce_id=$(echo "$dcra_json" | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    ep = a.get('dataCollectionEndpointId','')
    if ep:
        print(ep)
        break
" 2>/dev/null)
        dce_source="direct cluster association"
    fi

    if [[ -z "$dce_id" ]]; then
        echo -e "  ${Red}[ISSUE] No Data Collection Endpoint found in the DCR or as a direct cluster association.${NC}" | tee -a "$az_log"
        echo -e "          In AMPLS mode, a DCE must be explicitly configured so the agent can reach" | tee -a "$az_log"
        echo -e "          configuration endpoints over the private link." | tee -a "$az_log"
        echo -e "          -> Assign a DCE to the Container Insights DCR (dataCollectionEndpointId)" | tee -a "$az_log"
        echo -e "             and add it as a scoped resource in the AMPLS scope." | tee -a "$az_log"
        ANALYSIS_FINDINGS+=("AMPLS: No Data Collection Endpoint found in the DCR or cluster associations. A DCE must be configured and added to the AMPLS scope for config delivery over private link.")
        return
    fi

    local dce_json
    dce_json=$(az monitor data-collection endpoint show --ids "$dce_id" -o json 2>/dev/null)
    local dce_name dce_public_access
    dce_name=$(echo "$dce_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null)
    dce_public_access=$(echo "$dce_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('publicNetworkAccess',''))" 2>/dev/null)
    echo -e "  DCE found (via ${dce_source}): ${dce_name:-$dce_id}" | tee -a "$az_log"

    # ── Step 2: Verify the DCE is in an AMPLS scope ───────────────────────────
    local scopes_json
    scopes_json=$(az monitor private-link-scope list -o json 2>/dev/null)

    if [[ -z "$scopes_json" ]] || [[ "$scopes_json" == "[]" ]]; then
        echo -e "  ${Yellow}[WARN] No AMPLS scopes found in this subscription — cannot verify DCE scope membership.${NC}" | tee -a "$az_log"
        return
    fi

    local found_in_scope=false scope_name_found="" scope_access_mode_found=""
    while IFS='|' read -r scope_name scope_rg scope_access_mode; do
        local scoped_resources
        scoped_resources=$(az monitor private-link-scope scoped-resource list \
            --scope-name "$scope_name" --resource-group "$scope_rg" -o json 2>/dev/null)
        if DCE_ID="$dce_id" python3 -c "
import sys, json, os
dce = os.environ.get('DCE_ID','').lower()
found = any(r.get('linkedResourceId','').lower() == dce for r in json.load(sys.stdin))
sys.exit(0 if found else 1)
" <<< "$scoped_resources" 2>/dev/null; then
            found_in_scope=true
            scope_name_found="$scope_name"
            scope_access_mode_found="$scope_access_mode"
            break
        fi
    done < <(echo "$scopes_json" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    am = s.get('accessModeSettings') or s.get('properties',{}).get('accessModeSettings') or {}
    mode = am.get('ingestionAccessMode','Open')
    print(s['name'] + '|' + s['resourceGroup'] + '|' + mode)
" 2>/dev/null)

    if $found_in_scope; then
        echo -e "  ${Green}[OK] DCE '${dce_name:-$dce_id}' is a connected resource in AMPLS scope '${scope_name_found}' (ingestion access mode: ${scope_access_mode_found:-Open}).${NC}" | tee -a "$az_log"
        echo -e "       The agent can reach configuration endpoints over the private link." | tee -a "$az_log"
    else
        echo -e "  ${Red}[ISSUE] DCE '${dce_name:-$dce_id}' is NOT a connected resource in any AMPLS scope in this subscription.${NC}" | tee -a "$az_log"
        if [[ "$dce_public_access" == "Disabled" ]]; then
            echo -e "          publicNetworkAccess=Disabled — config refresh will fail once the cached" | tee -a "$az_log"
            echo -e "          configuration expires. The agent will stop collecting data." | tee -a "$az_log"
        else
            echo -e "          Config is currently fetched over the public internet (publicNetworkAccess=Enabled)." | tee -a "$az_log"
            echo -e "          This will break if public access is later disabled on the DCE." | tee -a "$az_log"
        fi
        echo -e "          -> Add '${dce_name:-$dce_id}' as a scoped resource in the AMPLS scope covering this cluster.${NC}" | tee -a "$az_log"
        if [[ "$dce_public_access" == "Disabled" ]]; then
            ANALYSIS_FINDINGS+=("AMPLS: DCE '${dce_name:-$dce_id}' is not in any AMPLS scope and has publicNetworkAccess=Disabled — config refresh will fail when the cache expires. Add it as a scoped resource immediately.")
        else
            ANALYSIS_FINDINGS+=("AMPLS: DCE '${dce_name:-$dce_id}' is not a connected resource in any AMPLS scope. Config delivery is going over public internet. Add it as a scoped resource so the agent can fetch configuration over the private link.")
        fi
    fi
}

# ─── _ensure_az_extension ────────────────────────────────────────────────────
# Checks if an Azure CLI extension is installed; installs it if not.
# Returns 0 on success, 1 if installation failed.
_ensure_az_extension() {
    local ext="$1" az_log="$2"
    if az extension show --name "$ext" &>/dev/null; then
        return 0
    fi
    echo -e "  ${Cyan}[INFO] Required Azure CLI extension not found: ${ext}. Installing...${NC}" | tee -a "$az_log"
    if az extension add --name "$ext" --yes 2>/dev/null; then
        echo -e "  ${Green}[OK] Installed extension: ${ext}${NC}" | tee -a "$az_log"
        return 0
    else
        echo -e "  ${Red}[ERROR] Failed to install extension '${ext}'. Dependent checks will be skipped.${NC}" | tee -a "$az_log"
        return 1
    fi
}

# ─── azure_config_check ───────────────────────────────────────────────────────
# Runs when --cluster-resource-id is provided. Checks auth mode, DCR/DCRA
# configuration, and workspace daily cap via the Azure CLI.
azure_config_check() {
    local separator="${Bold}════════════════════════════════════════════════════════${NC}"
    echo -e "\n${separator}" | tee -a Tool.log
    echo -e "${Bold} Azure Configuration Check${NC}" | tee -a Tool.log
    echo -e "${separator}" | tee -a Tool.log

    local az_log="azure-config-check.log"
    {
        echo "Azure Configuration Check - $(date)"
        echo "Cluster Resource ID: ${CLUSTER_RESOURCE_ID}"
        echo ""
    } > "$az_log"

    if ! type -p az > /dev/null 2>&1; then
        echo -e "${Red}[ERROR] Azure CLI (az) not found." | tee -a "$az_log" Tool.log
        echo -e "        Install Azure CLI and run 'az login' before using --cluster-resource-id.${NC}" | tee -a "$az_log"
        return
    fi

    if ! type -p python3 > /dev/null 2>&1; then
        echo -e "${Red}[ERROR] python3 not found. Azure configuration checks require python3 for JSON parsing.${NC}" | tee -a "$az_log" Tool.log
        return
    fi

    local account
    account=$(az account show --query "name" -o tsv 2>/dev/null)
    if [[ -z "$account" ]]; then
        echo -e "${Red}[ERROR] Not logged in to Azure CLI. Run 'az login' then retry.${NC}" | tee -a "$az_log" Tool.log
        return
    fi
    echo -e "Azure account: ${account}" | tee -a "$az_log"
    echo -e "Checking Container Insights configuration for cluster: ${CLUSTER_RESOURCE_ID##*/}" | tee -a "$az_log"

    # Ensure required extensions are installed before any dependent commands run
    echo -e "\n${Bold}Azure CLI Extensions:${NC}" | tee -a "$az_log"
    local ext_monitor=true ext_loganalytics=true
    _ensure_az_extension "monitor-control-service" "$az_log" || ext_monitor=false
    _ensure_az_extension "log-analytics"           "$az_log" || ext_loganalytics=false

    # Set subscription from the resource ID so commands target the right subscription
    local subscription cluster_rg cluster_name
    subscription=$(echo "$CLUSTER_RESOURCE_ID" | cut -d'/' -f3)
    cluster_rg=$(echo "$CLUSTER_RESOURCE_ID" | cut -d'/' -f5)
    cluster_name="${CLUSTER_RESOURCE_ID##*/}"
    az account set --subscription "$subscription" 2>/dev/null

    # ── Auth mode ─────────────────────────────────────────────────────────────
    echo -e "\n${Bold}Authentication Mode:${NC}" | tee -a "$az_log"

    local addon_enabled use_aad_auth
    addon_enabled=$(az aks show --resource-group "$cluster_rg" --name "$cluster_name" \
        --query "addonProfiles.omsAgent.enabled" -o tsv 2>/dev/null)
    [[ -z "$addon_enabled" ]] && \
        addon_enabled=$(az aks show --resource-group "$cluster_rg" --name "$cluster_name" \
            --query "addonProfiles.omsagent.enabled" -o tsv 2>/dev/null)

    use_aad_auth=$(az aks show --resource-group "$cluster_rg" --name "$cluster_name" \
        --query "addonProfiles.omsAgent.config.useAADAuth" -o tsv 2>/dev/null)
    [[ -z "$use_aad_auth" ]] && \
        use_aad_auth=$(az aks show --resource-group "$cluster_rg" --name "$cluster_name" \
            --query "addonProfiles.omsagent.config.useAADAuth" -o tsv 2>/dev/null)

    if [[ "$addon_enabled" != "true" ]]; then
        echo -e "  ${Red}[ERROR] Container Insights monitoring addon is not enabled on this cluster.${NC}" | tee -a "$az_log"
        echo -e "          Without this addon, the ama-logs agent is not deployed and no data will be collected." | tee -a "$az_log"
        echo -e "          Enable monitoring via the Azure Portal under the cluster's Insights blade, or via:" | tee -a "$az_log"
        echo -e "          az aks enable-addons --resource-group <rg> --name <cluster> --addons monitoring" | tee -a "$az_log"
        ANALYSIS_FINDINGS+=("Container Insights addon is not enabled on this cluster. Enable monitoring via the Azure Portal or CLI before troubleshooting further.")
    elif [[ "$use_aad_auth" == "true" ]]; then
        echo -e "  ${Green}[OK] Authentication mode: Managed Identity (MSI) — recommended configuration.${NC}" | tee -a "$az_log"
        echo -e "       The agent authenticates using the cluster's managed identity and uses a Data Collection Rule (DCR)" | tee -a "$az_log"
        echo -e "       to determine what data to collect and where to send it." | tee -a "$az_log"
        if $ext_monitor; then
            _check_dcr_dcra "$az_log"
        else
            echo -e "  ${Yellow}[SKIP] DCR/DCRA check skipped - monitor-control-service extension could not be installed.${NC}" | tee -a "$az_log"
        fi
    else
        echo -e "  ${Cyan}[INFO] Authentication mode: Legacy (shared workspace key).${NC}" | tee -a "$az_log"
        echo -e "         The agent uses a static workspace key rather than managed identity." | tee -a "$az_log"
        echo -e "         DCR-based configuration is not supported in this mode — collection settings are" | tee -a "$az_log"
        echo -e "         controlled via the container-azm-ms-agentconfig ConfigMap only." | tee -a "$az_log"
        echo -e "         Consider migrating to MSI auth mode for improved security and DCR-based management." | tee -a "$az_log"
    fi

    # _check_dcr_dcra may have populated WORKSPACE_ID — use it for the cap check
    if $ext_loganalytics; then
        _check_daily_cap "$az_log"
        _check_workspace_tables "$az_log" "$use_aad_auth"
        _check_workspace_network_isolation "$az_log"
    else
        echo -e "\n${Yellow}[SKIP] Daily cap check skipped - log-analytics extension could not be installed.${NC}" | tee -a "$az_log"
        echo -e "${Yellow}[SKIP] Table activity check skipped - log-analytics extension could not be installed.${NC}" | tee -a "$az_log"
        echo -e "${Yellow}[SKIP] Workspace network isolation check skipped - log-analytics extension could not be installed.${NC}" | tee -a "$az_log"
    fi

    if $USE_AMPLS && $ext_monitor; then
        _check_dce_ampls "$az_log"
    elif $USE_AMPLS; then
        echo -e "\n${Yellow}[SKIP] DCE AMPLS check skipped - monitor-control-service extension could not be installed.${NC}" | tee -a "$az_log"
    fi

    echo -e "\nAzure configuration check complete. Results saved to ${az_log}" | tee -a Tool.log
}

# ─── Main ─────────────────────────────────────────────────────────────────────
parse_args "$@"

separator="${Bold}════════════════════════════════════════════════════════${NC}"
echo -e "\n${separator}"
echo -e "${Bold} Container Insights Log Collection & Diagnostics${NC}"
echo -e "${separator}"
echo -e "This tool collects logs and runs diagnostics for the Azure Monitor Container"
echo -e "Insights agent (ama-logs) running in your AKS cluster. It will:"
echo -e ""
echo -e "  1. Collect logs from the ama-logs agent pods"
echo -e "     (the agent that ships your container logs and metrics to Azure Monitor)"
echo -e "  2. Test network connectivity to Azure Monitor endpoints"
echo -e "     (verifies firewalls, DNS, and proxies are not blocking data flow)"
echo -e "  3. Analyze collected logs for known error patterns"
echo -e "     (flags authentication failures, pipeline errors, and resource issues)"
if [[ -n "$CLUSTER_RESOURCE_ID" ]]; then
echo -e "  4. Check your Azure configuration via the Azure CLI"
echo -e "     (validates Data Collection Rules, auth mode, and workspace ingestion)"
fi
echo -e ""
echo -e "Results are saved to a compressed archive for sharing with support."
echo -e "Expected runtime: 2-5 minutes."
echo -e "${separator}"
echo -e ""

_cluster_name=""
if [[ -n "$CLUSTER_RESOURCE_ID" ]]; then
    _cluster_name="${CLUSTER_RESOURCE_ID##*/}"
else
    _cluster_name=$(kubectl config current-context 2>/dev/null | cut -c1-24 || true)
fi
# Capture both date and HHMMSS in a single date(1) invocation so the two halves
# can't straddle a second boundary. Format: CILogs.YYYYMMDD.HHMMSS.<cluster>
run_ts="$(date +%Y%m%d.%H%M%S)"
output_path="CILogs.${run_ts}.${_cluster_name:-unknown}"
mkdir -p "$output_path"
cd "$output_path"

init

ds_pod=$(kubectl get pods -n kube-system -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep -E '^ama-logs-[a-z0-9]{5}$' | head -n 1)
ds_win_pod=$(kubectl get pods -n kube-system -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep -E '^ama-logs-windows-[a-z0-9]{5}$' | head -n 1)
rs_pod=$(kubectl get pods -n kube-system -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep -E '^ama-logs-rs-' | head -n 1)

if [[ -z "$ds_pod" ]]; then
    echo -e "${Red}[ERROR] DaemonSet pod (ama-logs-XXXXX) not found in kube-system." | tee -a Tool.log
    echo -e "        Container Insights DaemonSet may not be running." | tee -a Tool.log
    echo -e "        Run: kubectl get daemonset -n kube-system | grep ama-logs${NC}" | tee -a Tool.log
    ANALYSIS_FINDINGS+=("DaemonSet pod not found. Run 'kubectl get daemonset -n kube-system' to check if ama-logs DaemonSet exists.")
else
    ds_logCollection
fi

if [[ -z "$ds_win_pod" ]]; then
    echo -e "${Cyan}[INFO] Windows agent pod not found - skipping Windows log collection.${NC}" | tee -a Tool.log
else
    win_logCollection
fi

if [[ -z "$rs_pod" ]]; then
    echo -e "${Red}[ERROR] ReplicaSet pod (ama-logs-rs-*) not found in kube-system." | tee -a Tool.log
    echo -e "        Container Insights ReplicaSet may not be running.${NC}" | tee -a Tool.log
    ANALYSIS_FINDINGS+=("ReplicaSet pod not found. Run 'kubectl get pods -n kube-system' to check ama-logs-rs status.")
else
    rs_logCollection
fi

other_logCollection

derive_cluster_info

if [[ -n "$CLUSTER_RESOURCE_ID" ]]; then
    azure_config_check
else
    echo -e "${Cyan}[INFO] Azure configuration checks skipped. Pass --cluster-resource-id to enable.${NC}" | tee -a Tool.log
fi

if ! $SKIP_NETWORK; then
    network_connectivity_check
else
    echo -e "${Cyan}[INFO] Network connectivity check skipped (--skip-network).${NC}" | tee -a Tool.log
fi

if ! $SKIP_ANALYSIS; then
    analyze_collected_logs
else
    echo -e "${Cyan}[INFO] Log analysis skipped (--skip-analysis).${NC}" | tee -a Tool.log
fi

cd ..
echo ""
echo -e "Archiving logs..."
tar -czf "${output_path}.tgz" "$output_path"
rm -rf "$output_path"
echo "log files have been written to ${output_path}.tgz in current folder"
