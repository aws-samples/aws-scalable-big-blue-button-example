#!/bin/bash
# Script handles the add and remove for Application Server instances into scalelite

# Exit on error
set -e

# Log file location
LOG_FILE="/var/log/scalelite-handler.log"
# Create log directory if it doesn't exist
if [ ! -d "/var/log" ]; then
    mkdir -p "/var/log"
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default log level
LOG_LEVEL="INFO"

# Function for logging
log() {
    local level=$1
    shift
    local message=$@
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_message="${timestamp} [${level}] - $message"

    # Log level hierarchy: ERROR=0, WARN=1, INFO=2, DEBUG=3
    case $level in
        "ERROR") level_num=0 ;;
        "WARN")  level_num=1 ;;
        "INFO")  level_num=2 ;;
        "DEBUG") level_num=3 ;;
        *) level_num=2 ;; # Default to INFO
    esac

    # Determine current log level number
    case $LOG_LEVEL in
        "ERROR") current_level=0 ;;
        "WARN")  current_level=1 ;;
        "INFO")  current_level=2 ;;
        "DEBUG") current_level=3 ;;
        *) current_level=2 ;; # Default to INFO
    esac

    # Only log if the message level is less than or equal to current log level
    if [ $level_num -le $current_level ]; then
        # Console output with colors
        case $level in
            "ERROR")
                echo -e "${RED}[ERROR]${NC} ${timestamp} - $message" >&2
                ;;
            "WARN")
                echo -e "${YELLOW}[WARN]${NC} ${timestamp} - $message"
                ;;
            "INFO")
                echo -e "${GREEN}[INFO]${NC} ${timestamp} - $message"
                ;;
            "DEBUG")
                echo -e "${BLUE}[DEBUG]${NC} ${timestamp} - $message"
                ;;
        esac

        # File logging (without colors)
        if ! echo "${log_message}" >> "${LOG_FILE}" 2>/dev/null; then
            echo -e "${RED}[ERROR]${NC} ${timestamp} - Failed to write to log file: ${LOG_FILE}" >&2
            echo -e "${RED}[ERROR]${NC} ${timestamp} - Please check permissions or run with sudo" >&2
            exit 1
        fi
    fi
}

# Function to rotate log file if it gets too large (>100MB)
rotate_log() {
    local max_size=$((100 * 1024 * 1024)) # 100MB in bytes
    if [ -f "$LOG_FILE" ]; then
        local file_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
        if [ "$file_size" -gt "$max_size" ]; then
            log "INFO" "Rotating log file (size: $file_size bytes)"
            mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d-%H%M%S)"
            touch "$LOG_FILE"
        fi
    fi
}

# Function to get Scalelite service information
get_scalelite_service() {
    local region=$1
    local cluster=$2
    
    log "DEBUG" "Getting Scalelite service from cluster: $cluster in region: $region"
    local service=$(aws ecs list-services \
        --region "$region" \
        --cluster "$cluster" \
        --query "serviceArns[?contains(@, 'BBBScaleliteService')]" \
        --output text | xargs -n 1 basename)
    
    if [ -z "$service" ]; then
        log "ERROR" "Failed to get Scalelite service"
        return 1
    fi
    
    log "DEBUG" "Found Scalelite service: $service"
    echo "$service"
}

# Function to get Scalelite task
get_scalelite_task() {
    local region=$1
    local cluster=$2
    local service=$3
    
    log "DEBUG" "Getting Scalelite task for service: $service"
    local task=$(aws ecs list-tasks \
        --region "$region" \
        --cluster "$cluster" \
        --service "$service" \
        --output text | awk -F"/" '{print $NF}' | rev | awk -F"/" '{print $1}' | rev)
    
    if [ -z "$task" ]; then
        log "ERROR" "Failed to get Scalelite task"
        return 1
    fi
    
    log "DEBUG" "Found Scalelite task: $task"
    echo "$task"
}

# Function to execute Scalelite command
execute_scalelite_command() {
    local region=$1
    local cluster=$2
    local task=$3
    local command=$4
    
    log "DEBUG" "Executing command in Scalelite container: $command"
    aws ecs execute-command \
        --region "$region" \
        --cluster "$cluster" \
        --task "$task" \
        --container scalelite-api \
        --interactive \
        --command "/bin/sh -c \"$command\""
}

# Check log file permissions and rotate if needed
rotate_log

# Log script start
log "INFO" "Starting Scalelite handler script"
log "DEBUG" "Script started with parameters: $@"

# Parse command line arguments
while getopts ":s:p:m:r:c:d" opt; do
    case $opt in
        p) SECRET="${OPTARG}"
           log "DEBUG" "Secret parameter received"
        ;;
        s) SERVER="${OPTARG}"
           log "DEBUG" "Server parameter received"
        ;;
        m) METHOD="${OPTARG}"
           log "DEBUG" "Method parameter received: ${OPTARG}"
        ;;
        r) REGION="${OPTARG}"
           log "DEBUG" "Region parameter received: ${OPTARG}"
        ;;
        c) ECS_CLUSTER="${OPTARG}"
           log "DEBUG" "ECS Cluster parameter received"
        ;;
        d) LOG_LEVEL="DEBUG"
           log "DEBUG" "Debug mode enabled"
        ;;
        \?) log "ERROR" "Invalid option -$OPTARG"
            exit 1
        ;;
    esac
done

# Validate required parameters
if [ -z "$SECRET" ] || [ -z "$SERVER" ] || [ -z "$METHOD" ] || [ -z "$REGION" ] || [ -z "$ECS_CLUSTER" ]; then
    log "ERROR" "Missing required parameters"
    log "ERROR" "Usage: $0 -s <server> -p <secret> -m <create|delete> -r <region> -c <ecs_cluster> [-d for debug]"
    exit 1
fi

# Get Scalelite service and task information
log "INFO" "Getting Scalelite service information"
SCALELITE_SERVICE=$(get_scalelite_service "$REGION" "$ECS_CLUSTER")
if [ $? -ne 0 ]; then
    log "ERROR" "Failed to get Scalelite service information"
    exit 1
fi

SCALELITE_TASK=$(get_scalelite_task "$REGION" "$ECS_CLUSTER" "$SCALELITE_SERVICE")
if [ $? -ne 0 ]; then
    log "ERROR" "Failed to get Scalelite task information"
    exit 1
fi

# Prepare and execute command based on method
case $METHOD in
    "create")
        log "INFO" "Adding server to Scalelite: $SERVER"
        COMMAND_STRING="id=\$(bin/rake servers:add[$SERVER,$SECRET] | tail -n 1 | sed 's/id: //g'); bin/rake servers:enable[\$id];"
        ;;
    "delete")
        log "INFO" "Removing server from Scalelite: $SERVER"
        COMMAND_STRING="id=\$(bin/rake servers | grep -B 1 \"$SERVER\" | head -n 1 | sed 's/id: //g'); bin/rake servers:panic[\$id] && bin/rake servers:remove[\$id]"
        ;;
    *)
        log "ERROR" "Invalid method: $METHOD. Must be 'create' or 'delete'"
        exit 1
        ;;
esac

# Execute the command
log "DEBUG" "Executing Scalelite command"
if execute_scalelite_command "$REGION" "$ECS_CLUSTER" "$SCALELITE_TASK" "$COMMAND_STRING"; then
    log "INFO" "Successfully executed $METHOD operation for server: $SERVER"
else
    log "ERROR" "Failed to execute $METHOD operation for server: $SERVER"
    exit 1
fi

log "INFO" "Script completed successfully"
exit 0
