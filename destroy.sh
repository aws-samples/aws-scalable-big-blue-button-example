#!/bin/sh
# BBB Application Infrastructure destruction script
# Author: David Surey - suredavi@amazon.de
# Disclaimer: NOT FOR PRODUCTION USE - Only for demo and testing purposes

# Color codes for output formatting
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
NC=$(printf '\033[0m')

# Logging configuration
LOG_LEVEL=${LOG_LEVEL:-"INFO"}  # Default to INFO if not set
LOG_FILE="/tmp/bbb-destroy-$(date +%Y%m%d-%H%M%S).log"

# Get numeric value for log level
get_log_level_value() {
    case $1 in
        "DEBUG") echo 0 ;;
        "INFO")  echo 1 ;;
        "WARN")  echo 2 ;;
        "ERROR") echo 3 ;;
        *)       echo 1 ;; # Default to INFO
    esac
}

# Logging function
log() {
    level=$1
    shift
    message=$*
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Check if level meets minimum level
    current_level=$(get_log_level_value "$level")
    minimum_level=$(get_log_level_value "$LOG_LEVEL")
    
    if [ "$current_level" -lt "$minimum_level" ]; then
        return 2
    fi

    # Color selection based on level
    case $level in
        "DEBUG") color=$BLUE ;;
        "INFO") color=$GREEN ;;
        "WARN") color=$YELLOW ;;
        "ERROR") color=$RED ;;
        *) color=$NC ;;
    esac

    # Output to console with color
    printf "%s [%s%s%s] %s\\n" "$timestamp" "$color" "$level" "$NC" "$message"
    
    # Output to log file without color
    printf "%s [%s] %s\\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
    
    # Exit on ERROR level messages
    if [ "$level" = "ERROR" ]; then
        exit 1
    fi
}

# Input validation function
validate_input() {
    param_name=$1
    param_value=$2
    
    if [ -z "$param_value" ]; then
        log "ERROR" "Parameter ${param_name} is required but not provided"
    fi
}

# Usage information
usage() {
    echo "Usage: $0 -p <aws-profile> -s <stack-name>"
    echo "Options:"
    echo "  -p : AWS Profile"
    echo "  -s : Stack Name"
    echo "  -l : Log Level (DEBUG|INFO|WARN|ERROR) - default: INFO"
    exit 1
}

# Initialize variables
BBBPROFILE=""
BBBSTACK=""

# Parse command line arguments
while getopts "p:s:l:" opt; do
    case $opt in
        p) BBBPROFILE="$OPTARG" ;;
        s) BBBSTACK="$OPTARG" ;;
        l) 
            case $OPTARG in
                DEBUG|INFO|WARN|ERROR) LOG_LEVEL="$OPTARG" ;;
                *) log "ERROR" "Invalid log level: $OPTARG. Valid levels are: DEBUG INFO WARN ERROR" ;;
            esac
            ;;
        *) usage ;;
    esac
done

# Validate all required parameters
log "DEBUG" "Validating input parameters..."
validate_input "AWS Profile" "$BBBPROFILE"
validate_input "Stack Name" "$BBBSTACK"

# Check for required tools
log "DEBUG" "Checking required tools..."
if ! command -v aws > /dev/null 2>&1; then
    log "ERROR" "aws CLI is not installed"
fi

# Main execution starts here
log "INFO" "Starting BBB destruction with AWS Profile: $BBBPROFILE"
log "INFO" "##################################################"

# Get source bucket name
log "INFO" "Getting source bucket name"
BBBPREPSTACK="${BBBSTACK}-Sources"
SOURCE=$(aws cloudformation describe-stack-resources \
    --profile "$BBBPROFILE" \
    --stack-name "$BBBPREPSTACK" \
    --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
    --output text)

if [ -z "$SOURCE" ]; then
    log "WARN" "Source bucket not found, continuing with deletion"
else
    log "INFO" "Found source bucket: $SOURCE"
fi

# Empty S3 buckets
log "INFO" "Emptying S3 buckets"
if [ -n "$SOURCE" ]; then
    log "DEBUG" "Emptying source bucket: $SOURCE"
    aws s3 rm "s3://$SOURCE" --recursive --profile "$BBBPROFILE"
fi

# Delete ECR Repository
log "INFO" "Deleting ECR Repository"
BBBECRSTACK="${BBBSTACK}-Registry"
if aws cloudformation describe-stacks --stack-name "$BBBECRSTACK" --profile "$BBBPROFILE" > /dev/null 2>&1; then
    log "DEBUG" "Deleting ECR stack: $BBBECRSTACK"
    aws cloudformation delete-stack --stack-name "$BBBECRSTACK" --profile "$BBBPROFILE"
    aws cloudformation wait stack-delete-complete --stack-name "$BBBECRSTACK" --profile "$BBBPROFILE"
else
    log "WARN" "ECR stack not found: $BBBECRSTACK"
fi

# Delete main stack
log "INFO" "Deleting main BBB stack"
if aws cloudformation describe-stacks --stack-name "$BBBSTACK" --profile "$BBBPROFILE" > /dev/null 2>&1; then
    log "DEBUG" "Deleting main stack: $BBBSTACK"
    aws cloudformation delete-stack --stack-name "$BBBSTACK" --profile "$BBBPROFILE"
    aws cloudformation wait stack-delete-complete --stack-name "$BBBSTACK" --profile "$BBBPROFILE"
else
    log "WARN" "Main stack not found: $BBBSTACK"
fi

# Delete source bucket stack
log "INFO" "Deleting source bucket stack"
if aws cloudformation describe-stacks --stack-name "$BBBPREPSTACK" --profile "$BBBPROFILE" > /dev/null 2>&1; then
    log "DEBUG" "Deleting source bucket stack: $BBBPREPSTACK"
    aws cloudformation delete-stack --stack-name "$BBBPREPSTACK" --profile "$BBBPROFILE"
    aws cloudformation wait stack-delete-complete --stack-name "$BBBPREPSTACK" --profile "$BBBPROFILE"
else
    log "WARN" "Source bucket stack not found: $BBBPREPSTACK"
fi

log "INFO" "Destruction completed successfully"
log "INFO" "Log file available at: $LOG_FILE"
exit 0
