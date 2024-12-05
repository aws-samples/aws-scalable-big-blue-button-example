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
    local profile=$3
    # First, find the service containing 'BBBScaleliteService' in its name
    local service_arn=$(aws ecs list-services \
        --profile "$PROFILE" \
        --cluster "$CLUSTER" \
        --output text \
        --query "serviceArns[?contains(@, 'BBBScaleliteService')]")

    if [ -z "$service_arn" ]; then
        echo "ERROR: Could not find Scalelite service in cluster $CLUSTER" >&2
        return 1
    fi

    # Get the tasks for the found service
    local task_arns=$(aws ecs list-tasks \
        --profile "$PROFILE" \
        --cluster "$CLUSTER" \
        --service-name "$(basename "$service_arn")" \
        --output text \
        --query 'taskArns[*]')

    if [ -z "$task_arns" ]; then
        echo "ERROR: No tasks found for Scalelite service" >&2
        return 1
    fi

    # Return the first task ARN
    echo "$(basename "$task_arns")"
}

# Function to execute interactive shell
debug_shell() {
    local region=$1
    local cluster=$2
    local task=$3
    local profile=$4

    log "Opening interactive shell..."
    aws ecs execute-command \
        --region "$region" \
        --cluster "$cluster" \
        --profile "$profile" \
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
    local profile=$5

    if [ -z "$server_id" ]; then
        log "Listing available servers..."
        aws ecs execute-command \
            --region "$region" \
            --cluster "$cluster" \
            --task "$task" \
            --profile "$profile" \
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
        --profile "$profile" \
        --container scalelite-api \
        --interactive \
        --command "/bin/sh -c 'bin/rake servers:panic[$server_id] && bin/rake servers:remove[$server_id]'"
}

# Function to prune all servers
prune_all() {
    local region=$1
    local cluster=$2
    local task=$3
    local profile=$4

    log "Pruning all servers..."
    aws ecs execute-command \
        --region "$region" \
        --cluster "$cluster" \
        --task "$task" \
        --profile "$profile" \   
        --container scalelite-api \
        --interactive \
        --command "/bin/sh -c 'for id in \$(bin/rake servers | grep \"id: \" | sed \"s/id: //\"); do bin/rake servers:panic[\$id] && bin/rake servers:remove[\$id]; done'"
}

# Parse command line arguments
while getopts ":r:c:m:i:p:" opt; do
    case $opt in
        r) REGION="${OPTARG}" ;;
        c) CLUSTER="${OPTARG}" ;;
        m) METHOD="${OPTARG}" ;;
        i) SERVER_ID="${OPTARG}" ;;
        p) PROFILE="${OPTARG}" ;;
        \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
    esac
done

# Validate required parameters
if [ -z "$REGION" ] || [ -z "$CLUSTER" ]; then
    echo "Usage: $0 -r <region> -c <cluster> -m <debug|delete|prune> [-i <server_id>]"
    exit 1
fi

# Get Scalelite task
TASK=$(get_scalelite_task "$REGION" "$CLUSTER" "$PROFILE")

# Execute requested method
case $METHOD in
    "debug")
        debug_shell "$REGION" "$CLUSTER" "$TASK" "$PROFILE"
        ;;
    "delete")
        delete_server "$REGION" "$CLUSTER" "$TASK" "$SERVER_ID" "$PROFILE"
        ;;
    "prune")
        prune_all "$REGION" "$CLUSTER" "$TASK" "$PROFILE"
        ;;
    *)
        echo "Invalid method. Use 'debug', 'delete', or 'prune'"
        exit 1
        ;;
esac
