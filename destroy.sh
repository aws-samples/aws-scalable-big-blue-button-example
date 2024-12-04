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
    printf "%s [%s%s%s] %s\n" "$timestamp" "$color" "$level" "$NC" "$message"
    
    # Output to log file without color
    printf "%s [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
    
    # Exit on ERROR level messages
    if [ "$level" = "ERROR" ]; then
        exit 1
    fi
}

# Function to monitor CloudFormation stack deletion events in real-time
monitor_stack_deletion() {
    local stack_name=$1
    local last_event_time
    last_event_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    log "DEBUG" "Starting deletion monitoring for stack: $stack_name"
    
    while true; do
        if ! aws cloudformation describe-stacks --stack-name "$stack_name" --profile "$BBBPROFILE" >/dev/null 2>&1; then
            log "INFO" "Stack $stack_name has been deleted successfully"
            return 0
        fi

        events=$(aws cloudformation describe-stack-events \
            --profile "$BBBPROFILE" \
            --stack-name "$stack_name" \
            --query 'StackEvents[?contains(ResourceStatus, `IN_PROGRESS`) || contains(ResourceStatus, `COMPLETE`) || contains(ResourceStatus, `FAILED`)]')
        
        echo "$events" | jq -r --arg timestamp "$last_event_time" '.[] | select(.Timestamp > $timestamp) | "\(.Timestamp) [\(.LogicalResourceId)] \(.ResourceStatus) - \(.ResourceStatusReason // "No reason provided")"' | while read -r line; do
            log "DEBUG" "$line"
        done
        
        # Get stack status
        stack_status=$(aws cloudformation describe-stacks \
            --profile "$BBBPROFILE" \
            --stack-name "$stack_name" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null)
        
        if [[ $stack_status =~ .*FAILED$ ]]; then
            log "ERROR" "Stack deletion failed with status: $stack_status"
            return 1
        fi
        
        last_event_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        sleep 5
    done
}

# Function to delete a CloudFormation stack with monitoring
delete_stack() {
    local stack_name=$1
    
    if aws cloudformation describe-stacks --stack-name "$stack_name" --profile "$BBBPROFILE" > /dev/null 2>&1; then
        log "DEBUG" "Deleting stack: $stack_name"
        if aws cloudformation delete-stack --stack-name "$stack_name" --profile "$BBBPROFILE"; then
            monitor_stack_deletion "$stack_name"
            return $?
        else
            log "ERROR" "Failed to initiate stack deletion for $stack_name"
            return 1
        fi
    else
        log "WARN" "Stack not found: $stack_name"
        return 0
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

# Function to delete all versions of objects in an S3 bucket
cleanup_s3_bucket() {
    local bucket_name=$1
    log "INFO" "Cleaning up S3 bucket: $bucket_name"
    
    # Check if bucket exists
    if ! aws s3api head-bucket --bucket "$bucket_name" --profile "$BBBPROFILE" 2>/dev/null; then
        log "WARN" "Bucket $bucket_name not found or no access"
        return 0
    fi

    log "INFO" "Removing all versions from bucket: $bucket_name"

    # Delete all versions (including delete markers)
    while true; do
        # Get versions and delete markers without pager
        versions=$(aws s3api list-object-versions \
            --bucket "$bucket_name" \
            --profile "$BBBPROFILE" \
            --output json \
            --no-cli-pager \
            --max-items 1000)
        
        # Extract version IDs and keys
        objects=$(echo "$versions" | jq -r '.Versions[]? | {Key:.Key,VersionId:.VersionId} | select(.VersionId != null)')
        markers=$(echo "$versions" | jq -r '.DeleteMarkers[]? | {Key:.Key,VersionId:.VersionId} | select(.VersionId != null)')

        # If no more versions or markers, break
        if [ -z "$objects" ] && [ -z "$markers" ]; then
            break
        fi

        # Prepare delete payload
        delete_payload=$(jq -n '{Objects: [inputs]}' <<<"$objects"$'\n'"$markers")

        # Delete batch of objects without pager
        if [ -n "$delete_payload" ]; then
            aws s3api delete-objects \
                --bucket "$bucket_name" \
                --delete "$delete_payload" \
                --profile "$BBBPROFILE" \
                --no-cli-pager \
                --output json || true
        fi
    done

    # Final cleanup of any remaining objects without pager
    aws s3 rm "s3://${bucket_name}" --recursive --profile "$BBBPROFILE" --no-cli-pager

    log "INFO" "Successfully cleaned up bucket: $bucket_name"
    return 0
}

# Get source bucket name and clean it up
log "INFO" "Getting source bucket name"
BBBPREPSTACK="${BBBSTACK}-Sources"
SOURCE=$(aws cloudformation describe-stack-resources \
    --profile "$BBBPROFILE" \
    --stack-name "$BBBPREPSTACK" \
    --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
    --output text)

if [ -n "$SOURCE" ]; then
    log "INFO" "Found source bucket: $SOURCE"
    # Clean up S3 bucket before deleting the stack
    if ! cleanup_s3_bucket "$SOURCE"; then
        log "WARN" "Failed to clean up S3 bucket, continuing with stack deletion"
    fi
else
    log "WARN" "Source bucket not found, continuing with deletion"
fi

# Function to delete ECR repository and its images
cleanup_ecr_repository() {
    local repository_name=$1
    log "INFO" "Attempting to delete ECR repository: $repository_name"
    
    # Force delete the repository and all images
    aws ecr delete-repository \
        --repository-name "$repository_name" \
        --force \
        --profile "$BBBPROFILE" >/dev/null 2>&1 || {
        log "DEBUG" "Repository $repository_name does not exist or already deleted"
    }
    
    return 0
}

# Get ECR repository names and delete them
log "INFO" "Getting ECR repository names"
BBBECRSTACK="${BBBSTACK}-registry"
ECR_REPOS=$(aws cloudformation describe-stack-resources \
    --profile "$BBBPROFILE" \
    --stack-name "$BBBECRSTACK" \
    --query "StackResources[?ResourceType=='AWS::ECR::Repository'].PhysicalResourceId" \
    --output text)

if [ -n "$ECR_REPOS" ]; then
    log "INFO" "Found ECR repositories"
    
    # Process each repository name
    for repo in bigbluebutton/greenlight blindsidenetwks/scalelite; do
        if [ -n "$repo" ]; then
            log "INFO" "Processing repository: '$repo'"
            if ! cleanup_ecr_repository "$repo"; then
                log "WARN" "Failed to delete ECR repository: '$repo'"
            fi
        fi
    done
else
    log "WARN" "No ECR repositories found, continuing with deletion"
fi

# Delete main stack
log "INFO" "Deleting main BBB stack"
delete_stack "$BBBSTACK"

# Delete ECR Repository stack
log "INFO" "Deleting ECR Repository stack"
delete_stack "$BBBECRSTACK"

# Delete source bucket stack
log "INFO" "Deleting source bucket stack"
delete_stack "$BBBPREPSTACK"

log "INFO" "Destruction completed successfully"
log "INFO" "Log file available at: $LOG_FILE"
exit 0
