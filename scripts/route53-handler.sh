#!/bin/bash
# Script handler for route53 entries on startup / shutdown

# Exit on error
set -e

# Log file location
LOG_FILE="/var/log/route53-handler.log"
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

# Function to get metadata
get_metadata() {
    local metadata_path=$1
    local token

    log "DEBUG" "Requesting IMDSv2 token..."
    token=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        -s -f 2>/dev/null)

    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to get IMDSv2 token"
        return 1
    fi

    log "DEBUG" "Token received successfully"
    log "DEBUG" "Requesting metadata: $metadata_path"
    
    local result=$(curl -H "X-aws-ec2-metadata-token: $token" \
        -s -f "http://169.254.169.254/latest/meta-data/${metadata_path}" 2>/dev/null)

    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to get metadata from path: $metadata_path"
        return 1
    fi

    log "DEBUG" "Successfully retrieved metadata"
    echo "$result"
}

# Check log file permissions and rotate if needed
rotate_log

# Log script start
log "INFO" "Starting Route53 handler script"
log "DEBUG" "Script started with parameters: $@"

# Parse command line arguments
while getopts ":h:m:z:d" opt; do
    case $opt in
        h) HOSTNAME="${OPTARG}"
           log "DEBUG" "Hostname parameter received: ${OPTARG}"
        ;;
        m) METHOD="${OPTARG}"
           log "DEBUG" "Method parameter received: ${OPTARG}"
        ;;
        z) ZONE="${OPTARG}"
           log "DEBUG" "Zone parameter received: ${OPTARG}"
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
if [ -z "$HOSTNAME" ] || [ -z "$METHOD" ] || [ -z "$ZONE" ]; then
    log "ERROR" "Missing required parameters"
    log "ERROR" "Usage: $0 -h <hostname> -m <create|delete> -z <zone> [-d for debug]"
    exit 1
fi

# Main logic
case $METHOD in
    "create")
        log "INFO" "Starting DNS record creation process"
        log "DEBUG" "Parameters received:"
        log "DEBUG" "  Hostname: ${HOSTNAME}"
        log "DEBUG" "  Zone: ${ZONE}"
        log "DEBUG" "  Log Level: ${LOG_LEVEL}"

        # Get instance IP
        log "DEBUG" "Attempting to get instance IP..."
        instance_ipv4=$(get_metadata "public-ipv4")
        if [ $? -ne 0 ] || [ -z "$instance_ipv4" ]; then
            log "ERROR" "Failed to get instance IP address"
            exit 1
        fi
        
        instance_ipv4=$(echo "$instance_ipv4" | tr -d '\n\r\t ')
        log "INFO" "Retrieved IP Address: ${instance_ipv4}"

        # Create DNS record
        log "INFO" "Creating Route53 record..."
        log "DEBUG" "Executing cli53 command..."
        if /usr/local/bin/cli53 rrcreate --replace "${ZONE}" "${HOSTNAME} 60 A ${instance_ipv4}"; then
            log "INFO" "Successfully created DNS record"
        else
            log "ERROR" "Failed to create DNS record"
            exit 1
        fi
        ;;

    "delete")
        log "INFO" "Starting DNS record deletion process"
        log "DEBUG" "Attempting to delete record for ${HOSTNAME} in zone ${ZONE}"
        
        if /usr/local/bin/cli53 rrdelete "${ZONE}" "${HOSTNAME}" A; then
            log "INFO" "Successfully deleted DNS record"
        else
            log "ERROR" "Failed to delete DNS record"
            exit 1
        fi
        ;;

    *)
        log "ERROR" "Invalid method: ${METHOD}. Must be 'create' or 'delete'"
        exit 1
        ;;
esac

log "INFO" "Script completed successfully"
exit 0
