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

    local node_check
    node_check=$(kubectl get nodes 2>&1)
    if [[ $node_check == *"refused"* ]] || [[ $node_check == *"unable to connect"* ]] || [[ $node_check == *"was refused"* ]]; then
        echo -e "${Red}[ERROR] Cannot connect to the cluster." | tee -a Tool.log
        echo -e "        Run: az aks get-credentials --resource-group <RG> --name <CLUSTER>${NC}" | tee -a Tool.log
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
                echo -e "       Network tests will use privatelink endpoints.${NC}" | tee -a Tool.log
            fi
        fi
    fi
}

# ─── ds_logCollection ─────────────────────────────────────────────────────────
ds_logCollection() {
    echo -e "\nCollecting logs from DaemonSet pod: ${ds_pod}..." | tee -a Tool.log
    kubectl describe pod "${ds_pod}" --namespace=kube-system > "describe_${ds_pod}.txt" 2>&1
    kubectl logs "${ds_pod}" --container ama-logs --namespace=kube-system > "logs_${ds_pod}.txt" 2>&1
    kubectl logs "${ds_pod}" --container ama-logs-prometheus --namespace=kube-system > "logs_${ds_pod}_prom.txt" 2>/dev/null
    if kubectl logs "${ds_pod}" --container ama-logs --namespace=kube-system --previous > "logs_${ds_pod}_previous.txt" 2>/dev/null; then
        echo -e "  ${Yellow}[WARN] Previous (pre-restart) logs collected for ${ds_pod} - this pod has restarted at least once.${NC}" | tee -a Tool.log
        echo -e "         Restarts often indicate crashes due to resource limits (OOMKill), configuration errors," | tee -a Tool.log
        echo -e "         or a failing dependency. Review logs_${ds_pod}_previous.txt to see what caused the restart.${NC}" | tee -a Tool.log
    fi
    kubectl exec "${ds_pod}" -n kube-system -c ama-logs --request-timeout=10m -- ps -ef > "process_${ds_pod}.txt" 2>/dev/null

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

        # A missing or empty configchunks dir means the agent has not received its DCR config.
        local chunk_count
        chunk_count=$(kubectl exec "${ds_pod}" -n kube-system -c ama-logs \
            -- ls /etc/mdsd.d/config-cache/configchunks/ 2>/dev/null | grep -c '.json' || echo 0)
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
        ls /var/opt/microsoft/docker-cimprov/state/ContainerInventory > "containerID_${ds_pod}.txt" 2>&1

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

    echo -e "Complete log collection from ${ds_pod}!" | tee -a Tool.log
}

# ─── win_logCollection ────────────────────────────────────────────────────────
win_logCollection() {
    echo -e "\nCollecting logs from Windows pod: ${ds_win_pod} (this may take several minutes)..." | tee -a Tool.log
    kubectl describe pod "${ds_win_pod}" --namespace=kube-system > "describe_${ds_win_pod}.txt" 2>&1
    kubectl logs "${ds_win_pod}" --container ama-logs-windows --namespace=kube-system > "logs_${ds_win_pod}.txt" 2>&1
    kubectl exec "${ds_win_pod}" -n kube-system --request-timeout=10m -- powershell Get-Process > "process_${ds_win_pod}.txt" 2>/dev/null

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

    mkdir -p ama-logs-windows-daemonset
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
    kubectl describe pod "${rs_pod}" --namespace=kube-system > "describe_${rs_pod}.txt" 2>&1
    kubectl logs "${rs_pod}" --container ama-logs --namespace=kube-system > "logs_${rs_pod}.txt" 2>&1
    if kubectl logs "${rs_pod}" --container ama-logs --namespace=kube-system --previous > "logs_${rs_pod}_previous.txt" 2>/dev/null; then
        echo -e "  ${Yellow}[WARN] Previous (pre-restart) logs collected for ${rs_pod} - this pod has restarted at least once.${NC}" | tee -a Tool.log
        echo -e "         Restarts often indicate crashes due to resource limits (OOMKill), configuration errors," | tee -a Tool.log
        echo -e "         or a failing dependency. Review logs_${rs_pod}_previous.txt to see what caused the restart.${NC}" | tee -a Tool.log
    fi
    kubectl exec "${rs_pod}" -n kube-system -c ama-logs --request-timeout=10m -- ps -ef > "process_${rs_pod}.txt" 2>/dev/null

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

        local chunk_count
        chunk_count=$(kubectl exec "${rs_pod}" -n kube-system -c ama-logs \
            -- ls /etc/mdsd.d/config-cache/configchunks/ 2>/dev/null | grep -c '.json' || echo 0)
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

    local deploy
    deploy=$(kubectl get deployment --namespace=kube-system | grep -E ama-logs | head -n 1 | awk '{print $1}')
    if [[ -z "$deploy" ]]; then
        echo -e "${Red}[ERROR] No ama-logs deployment found in kube-system." | tee -a Tool.log
        echo -e "        Container Insights addon may not be enabled on this cluster.${NC}" | tee -a Tool.log
        ANALYSIS_FINDINGS+=("No ama-logs deployment found. Container Insights addon may not be enabled or may have been removed from the cluster.")
    else
        echo -e "  Collecting deployment info for: ${deploy}"
        kubectl get deployment "$deploy" --namespace=kube-system -o yaml > "deployment_${deploy}.yaml"
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
            kubectl get configmaps "$cm_name" --namespace=kube-system -o yaml > "${cm_name}.yaml"
        fi
    done

    # Node info + quick status snapshots for the archive
    kubectl get nodes > node.txt 2>&1
    kubectl get nodes -o json > node-detailed.json 2>&1
    kubectl get daemonset -n kube-system | grep ama-logs > daemonset-status.txt 2>&1
    kubectl get pods -n kube-system | grep ama-logs > pod-status.txt 2>&1
    kubectl get events -n kube-system --sort-by='.lastTimestamp' 2>/dev/null | grep -i ama-logs > ama-logs-events.txt 2>&1

    # Agent image version
    local agent_image=""
    if [[ -n "$ds_pod" ]]; then
        agent_image=$(kubectl get pod "$ds_pod" -n kube-system \
            -o jsonpath='{.spec.containers[?(@.name=="ama-logs")].image}' 2>/dev/null)
    fi
    if [[ -n "$agent_image" ]]; then
        echo -e "  ${Cyan}[INFO] ama-logs image: ${agent_image}${NC}" | tee -a Tool.log
        echo "ama-logs image: ${agent_image}" > agent-version.txt
    fi

    # Resource usage snapshot (requires metrics-server)
    kubectl top nodes > top-nodes.txt 2>&1 \
        || echo "(kubectl top not available - metrics-server may not be installed)" > top-nodes.txt
    kubectl top pods -n kube-system > top-pods-kube-system.txt 2>&1 \
        || echo "(kubectl top not available)" > top-pods-kube-system.txt

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

    # Check which tools are available inside the pod
    local has_curl has_nslookup
    has_curl=$(kubectl exec "${test_pod}"    -n kube-system -c ama-logs -- which curl     2>/dev/null)
    has_nslookup=$(kubectl exec "${test_pod}" -n kube-system -c ama-logs -- which nslookup 2>/dev/null)

    # Build the endpoint list based on what info we have
    local -a endpoints=()

    # Static endpoints - always required
    endpoints+=(
        "dc.services.visualstudio.com"
        "login.microsoftonline.com"
        "global.handler.control.monitor.azure.com"
    )

    # Region-specific endpoints (managed identity / DCR fetch)
    if [[ -n "$CLUSTER_REGION" ]]; then
        endpoints+=(
            "${CLUSTER_REGION}.handler.control.monitor.azure.com"
        )
    fi

    # Workspace-specific ODS/OMS endpoints
    if [[ -n "$WORKSPACE_ID" ]]; then
        if $USE_AMPLS; then
            endpoints+=(
                "${WORKSPACE_ID}.privatelink.ods.opinsights.azure.com"
                "${WORKSPACE_ID}.privatelink.oms.opinsights.azure.com"
            )
        else
            endpoints+=(
                "${WORKSPACE_ID}.ods.opinsights.azure.com"
                "${WORKSPACE_ID}.oms.opinsights.azure.com"
            )
        fi
    fi

    local net_failures=0
    local dns_failures=0

    echo -e "\nTesting connectivity to Azure Monitor endpoints from inside the agent pod." | tee -a "$net_log"
    echo -e "These endpoints must be reachable for the agent to ingest data:" | tee -a "$net_log"
    echo -e "  - login.microsoftonline.com        : Azure AD token acquisition (MSI authentication)" | tee -a "$net_log"
    echo -e "  - *.handler.control.monitor.azure.com : DCR / configuration delivery" | tee -a "$net_log"
    echo -e "  - *.ods.opinsights.azure.com        : Log data ingestion endpoint" | tee -a "$net_log"
    echo -e "  - *.oms.opinsights.azure.com        : Agent heartbeat and management" | tee -a "$net_log"
    echo -e "  - dc.services.visualstudio.com      : Agent diagnostics / telemetry" | tee -a "$net_log"

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
        echo -e "         To test manually: kubectl exec -it ${test_pod} -n kube-system -c ama-logs -- nslookup login.microsoftonline.com" | tee -a "$net_log"
    fi

    # ── HTTPS connectivity tests ──────────────────────────────────────────────
    if [[ -n "$has_curl" ]]; then
        echo -e "\n${Bold}HTTPS Connectivity (curl):${NC}" | tee -a "$net_log"
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
        echo -e "         To test manually: kubectl exec -it ${test_pod} -n kube-system -c ama-logs -- curl -v --max-time 10 https://login.microsoftonline.com" | tee -a "$net_log"
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
            "403|InvalidAccess|Unauthorized|Authentication failed|forbidden|Access denied" \
            "Authentication/authorization errors (403) detected." \
            "Verify the cluster managed identity has Monitoring Metrics Publisher role on the Log Analytics Workspace. If AMPLS is in use, check AMPLS scope includes the workspace."; then
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
    for desc in describe_*.txt; do
        [[ ! -f "$desc" ]] && continue
        echo -e "\nAnalyzing ${desc} for restarts and OOMKill..." | tee -a "$analysis_log"

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
            echo -e "  ${Yellow}[WARN] Elevated restart count (${restart_count}) detected in ${desc}." | tee -a "$analysis_log"
            echo -e "         The ama-logs container has restarted ${restart_count} time(s), which may indicate crashes or" | tee -a "$analysis_log"
            echo -e "         repeated OOM kills. Check previous pod logs (logs_*_previous.txt) for the crash reason.${NC}" | tee -a "$analysis_log"
            ANALYSIS_FINDINGS+=("High restart count (${restart_count}) in ${desc}. Review logs_*_previous.txt for crash reason.")
            found_any=true
        else
            echo -e "  ${Green}[OK] No OOMKill events detected. Restart count: ${restart_count}.${NC}" | tee -a "$analysis_log"
        fi
    done

    # ── container-azm-ms-agentconfig ConfigMap ────────────────────────────────
    local cm_file="container-azm-ms-agentconfig.yaml"
    if [[ -f "$cm_file" ]]; then
        echo -e "\nAnalyzing ${cm_file}..." | tee -a "$analysis_log"
        local cm_issues=0

        # Collection disabled for any major data type
        while IFS= read -r line; do
            if echo "$line" | grep -qiE "enabled\s*=\s*false"; then
                local section=""
                section=$(grep -B10 "$line" "$cm_file" 2>/dev/null | grep -oP '\[log_collection_settings\.\K[^\]]+' | tail -1)
                echo -e "  ${Yellow}[WARN] Collection disabled: ${line// /} (section: ${section:-unknown})${NC}" | tee -a "$analysis_log"
                ANALYSIS_FINDINGS+=("ConfigMap: collection disabled for section '${section:-unknown}' via 'enabled = false'. Verify this is intentional.")
                ((cm_issues++)); found_any=true
            fi
        done < <(grep -iE "enabled\s*=\s*false" "$cm_file" 2>/dev/null)

        # Namespace filtering active
        if grep -qiE "exclude_namespaces|include_namespaces" "$cm_file" 2>/dev/null; then
            local ns_lines
            ns_lines=$(grep -iE "exclude_namespaces|include_namespaces" "$cm_file" | head -5 | sed 's/^[[:space:]]*//')
            echo -e "  ${Yellow}[WARN] Namespace filtering is configured in the ConfigMap:${NC}" | tee -a "$analysis_log"
            echo "$ns_lines" | sed 's/^/    /' | tee -a "$analysis_log"
            echo -e "         Verify this is not excluding namespaces that are expected to be collected." | tee -a "$analysis_log"
            ANALYSIS_FINDINGS+=("ConfigMap: namespace filtering configured. Verify expected namespaces are not excluded.")
            ((cm_issues++)); found_any=true
        fi

        if [[ "$cm_issues" -eq 0 ]]; then
            echo -e "  ${Green}[OK] No collection-disabling settings detected in ConfigMap${NC}" | tee -a "$analysis_log"
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
]))
" 2>/dev/null)

        local dcr_name ws_id ws_resource_id streams interval ns_filter clv2
        IFS='|' read -r dcr_name ws_id ws_resource_id streams interval ns_filter clv2 <<< "$fields"

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
        --analytics-query "_LogOperation | where TimeGenerated >= ago(7d) | search 'OverQuota' | summarize count()" \
        -o json 2>/dev/null)

    if [[ -z "$cap_result" ]] || [[ "$cap_result" == "null" ]]; then
        echo -e "  ${Yellow}[WARN] Daily cap query could not be executed. This is typically due to insufficient" | tee -a "$az_log"
        echo -e "         permissions on the Log Analytics workspace. Continuing with remaining checks.${NC}" | tee -a "$az_log"
        return
    fi

    local hit_count
    hit_count=$(echo "$cap_result" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    tables = data if isinstance(data, list) else data.get('tables', [])
    for t in tables:
        rows = t.get('rows', [])
        if rows:
            print(int(rows[0][0]))
            sys.exit(0)
    print(0)
except:
    print(0)
" 2>/dev/null)

    if [[ "${hit_count:-0}" -gt 0 ]]; then
        echo -e "  ${Red}[ISSUE] Daily cap has been hit ${hit_count} time(s) in the last 7 days.${NC}" | tee -a "$az_log"
        echo -e "          Data ingested after the cap resets is dropped until the next reset window." | tee -a "$az_log"
        echo -e "          Intermittent data loss throughout the day is a common symptom of this." | tee -a "$az_log"
        ANALYSIS_FINDINGS+=("Daily cap hit ${hit_count} time(s) in the last 7 days. Data is being dropped once the cap is reached each day. The workspace daily cap must be raised or removed to restore continuous collection.")
    else
        echo -e "  ${Green}[OK] Daily ingestion cap has not been triggered in the last 7 days.${NC}" | tee -a "$az_log"
        echo -e "       Data ingestion has not been interrupted by a workspace cap limit." | tee -a "$az_log"
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
    for r in rows:
        table = r.get('Type', '')
        count = r.get('Rows', r.get('count_', 0))
        last  = str(r.get('LastIngest', r.get('max_TimeGenerated', ''))).replace('T', ' ').split('.')[0]
        print(f'  {table:<35} {str(count):>8}  {last}')
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
        echo "$table_output" | tee -a "$az_log"
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
        --query "addonProfiles.omsagent.enabled" -o tsv 2>/dev/null)
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
    else
        echo -e "\n${Yellow}[SKIP] Daily cap check skipped - log-analytics extension could not be installed.${NC}" | tee -a "$az_log"
        echo -e "${Yellow}[SKIP] Table activity check skipped - log-analytics extension could not be installed.${NC}" | tee -a "$az_log"
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
output_path="CILogs.$(date +%Y%m%d).${_cluster_name:-unknown}"
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

if [[ -n "$CLUSTER_RESOURCE_ID" ]]; then
    azure_config_check
else
    echo -e "${Cyan}[INFO] Azure configuration checks skipped. Pass --cluster-resource-id to enable.${NC}" | tee -a Tool.log
fi

derive_cluster_info

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
