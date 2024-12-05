#!/bin/bash
set -e

# Basic logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to get Scalelite task
get_scalelite_task() {
    local region=$1
    local cluster=$2
    
    local task=$(aws ecs list-tasks \
        --region "$region" \
        --cluster "$cluster" \
        --service-name "BBBScaleliteService" \
        --output text | awk -F"/" '{print $NF}')

    if [ -z "$task" ]; then
        log "ERROR: Failed to get Scalelite task"
        exit 1
    fi
    echo "$task"
}

# Function to execute interactive shell
debug_shell() {
    local region=$1
    local cluster=$2
    local task=$3

    log "Opening interactive shell..."
    aws ecs execute-command \
        --region "$region" \
        --cluster "$cluster" \
        --task "$task" \
        --container scalelite-api \
        --interactive \
        --command "/bin/sh"
}

# Function to delete a specific server
delete_server() {
    local region=$1
    local cluster=$2
    local task=$3
    local server_id=$4

    if [ -z "$server_id" ]; then
        log "Listing available servers..."
        aws ecs execute-command \
            --region "$region" \
            --cluster "$cluster" \
            --task "$task" \
            --container scalelite-api \
            --interactive \
            --command "/bin/sh -c 'bin/rake servers'"
        
        read -p "Enter server ID to delete (or press enter to cancel): " server_id
        
        if [ -z "$server_id" ]; then
            log "Operation cancelled"
            exit 0
        fi
    fi

    log "Deleting server ID: $server_id"
    aws ecs execute-command \
        --region "$region" \
        --cluster "$cluster" \
        --task "$task" \
        --container scalelite-api \
        --interactive \
        --command "/bin/sh -c 'bin/rake servers:panic[$server_id] && bin/rake servers:remove[$server_id]'"
}

# Function to prune all servers
prune_all() {
    local region=$1
    local cluster=$2
    local task=$3

    log "Pruning all servers..."
    aws ecs execute-command \
        --region "$region" \
        --cluster "$cluster" \
        --task "$task" \
        --container scalelite-api \
        --interactive \
        --command "/bin/sh -c 'for id in \$(bin/rake servers | grep \"id: \" | sed \"s/id: //\"); do bin/rake servers:panic[\$id] && bin/rake servers:remove[\$id]; done'"
}

# Parse command line arguments
while getopts ":r:c:m:i:" opt; do
    case $opt in
        r) REGION="${OPTARG}" ;;
        c) CLUSTER="${OPTARG}" ;;
        m) METHOD="${OPTARG}" ;;
        i) SERVER_ID="${OPTARG}" ;;
        \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
    esac
done

# Validate required parameters
if [ -z "$REGION" ] || [ -z "$CLUSTER" ]; then
    echo "Usage: $0 -r <region> -c <cluster> -m <debug|delete|prune> [-i <server_id>]"
    exit 1
fi

# Get Scalelite task
TASK=$(get_scalelite_task "$REGION" "$CLUSTER")

# Execute requested method
case $METHOD in
    "debug")
        debug_shell "$REGION" "$CLUSTER" "$TASK"
        ;;
    "delete")
        delete_server "$REGION" "$CLUSTER" "$TASK" "$SERVER_ID"
        ;;
    "prune")
        prune_all "$REGION" "$CLUSTER" "$TASK"
        ;;
    *)
        echo "Invalid method. Use 'debug', 'delete', or 'prune'"
        exit 1
        ;;
esac
