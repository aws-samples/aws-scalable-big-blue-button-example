#!/bin/bash
# BBB Application Infrastructure destruction script
# Author: David Surey - suredavi@amazon.de
# Disclaimer: NOT FOR PRODUCTION USE - Only for demo and testing purposes

# Color codes for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging configuration
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
LOG_LEVEL=${LOG_LEVEL:-"INFO"}  # Default to INFO if not set
LOG_FILE="/tmp/bbb-destroy-$(date +%Y%m%d-%H%M%S).log"

# Logging function
log() {
    local level=$1
    shift
    local message=$*
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Check if level exists and meets minimum level
    [[ ${LOG_LEVELS[$level]} ]] || return 1
    (( ${LOG_LEVELS[$level]} < ${LOG_LEVELS[$LOG_LEVEL]} )) && return 2

    # Color selection based on level
    local color=""
    case $level in
        "DEBUG") color=$BLUE ;;
        "INFO") color=$GREEN ;;
        "WARN") color=$YELLOW ;;
        "ERROR") color=$RED ;;
    esac

    # Output to console with color and to log file without color
    echo -e "${timestamp} [${color}${level}${NC}] ${message}" | tee >(sed "s/\x1B\[[0-9;]\{1,\}[A-Za-z]//g" >> "$LOG_FILE")
    
    # Exit on ERROR level messages
    if [[ $level == "ERROR" ]]; then
        exit 1
    fi
}

# Input validation function
validate_input() {
    local param_name=$1
    local param_value=$2
    
    if [[ -z "$param_value" ]]; then
        log "ERROR" "Parameter ${param_name} is required but not provided"
    fi
}

# Usage information
usage() {
    echo -e "${BLUE}Usage: $0 -p <aws-profile> -s <stack-name>${NC}"
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
while getopts ":p:s:l:" opt; do
    case $opt in
        p) BBBPROFILE="$OPTARG" ;;
        s) BBBSTACK="$OPTARG" ;;
        l) 
            if [[ ${LOG_LEVELS[$OPTARG]} ]]; then
                LOG_LEVEL="$OPTARG"
            else
                log "ERROR" "Invalid log level: $OPTARG. Valid levels are: ${!LOG_LEVELS[*]}"
            fi
            ;;
        \?) log "ERROR" "Invalid option -$OPTARG" ;;
        :) log "ERROR" "Option -$OPTARG requires an argument" ;;
    esac
done

# Validate all required parameters
log "DEBUG" "Validating input parameters..."
validate_input "AWS Profile" "$BBBPROFILE"
validate_input "Stack Name" "$BBBSTACK"

# Check for required tools
log "DEBUG" "Checking required tools..."
if ! command -v aws >/dev/null 2>&1; then
    log "ERROR" "aws CLI is not installed"
fi

if ! command -v jq >/dev/null 2>&1; then
    log "ERROR" "jq is not installed"
fi

# Function to clean ECR repositories
clean_ecr_repositories() {
    log "INFO" "Checking environment type..."
    ENVIRONMENTTYPE=$(jq -r ".Parameters.BBBEnvironmentType" bbb-on-aws-param.json)
    
    if [ "$ENVIRONMENTTYPE" == 'scalable' ]; then
        log "INFO" "Cleaning ECR repositories..."
        
        GREENLIGHTREGISTRY=$(aws ecr describe-repositories --profile=$BBBPROFILE --query 'repositories[?contains(repositoryName, `greenlight`)].repositoryName' --output text)
        SCALELITEREGISTRY=$(aws ecr describe-repositories --profile=$BBBPROFILE --query 'repositories[?contains(repositoryName, `scalelite`)].repositoryName' --output text)
        
        log "DEBUG" "Found Greenlight registry: $GREENLIGHTREGISTRY"
        log "DEBUG" "Found Scalelite registry: $SCALELITEREGISTRY"
        
        if [ -n "$GREENLIGHTREGISTRY" ]; then
            log "INFO" "Cleaning Greenlight repository..."
            IMAGESGREENLIGHT=$(aws --profile $BBBPROFILE ecr describe-images --repository-name $GREENLIGHTREGISTRY --output json | jq '.[].[] | select (.imagePushedAt > 0) | .imageDigest')
            for IMAGE in ${IMAGESGREENLIGHT[*]}; do
                log "DEBUG" "Deleting image $IMAGE from Greenlight repository"
                aws ecr --profile $BBBPROFILE batch-delete-image --repository-name $GREENLIGHTREGISTRY --image-ids imageDigest=$IMAGE
            done
        fi

        if [ -n "$SCALELITEREGISTRY" ]; then
            log "INFO" "Cleaning Scalelite repository..."
            IMAGESSCALELITE=$(aws --profile $BBBPROFILE ecr describe-images --repository-name $SCALELITEREGISTRY --output json | jq '.[].[] | select (.imagePushedAt > 0) | .imageDigest')
            for IMAGE in ${IMAGESSCALELITE[*]}; do
                log "DEBUG" "Deleting image $IMAGE from Scalelite repository"
                aws ecr --profile $BBBPROFILE batch-delete-image --repository-name $SCALELITEREGISTRY --image-ids imageDigest=$IMAGE
            done
        fi
    fi
}

# Function to clean S3 bucket
clean_s3_bucket() {
    BBBPREPSTACK="${BBBSTACK}-Sources"
    log "INFO" "Retrieving S3 bucket name from stack $BBBPREPSTACK"
    
    SOURCE=$(aws cloudformation describe-stack-resources --profile $BBBPROFILE --stack-name $BBBPREPSTACK --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" --output text)
    
    if [ -n "$SOURCE" ]; then
        log "INFO" "Cleaning S3 bucket: $SOURCE"
        log "DEBUG" "Listing object versions..."
        aws s3api --profile=$BBBPROFILE list-object-versions \
            --bucket $SOURCE \
            --query "Versions[].Key" \
            --output json | jq 'unique' | jq -r '.[]' | while read key; do
            log "DEBUG" "Processing versions of object: $key"
            aws s3api --profile=$BBBPROFILE list-object-versions \
                --bucket $SOURCE \
                --prefix $key \
                --query "Versions[].VersionId" \
                --output json | jq 'unique' | jq -r '.[]' | while read version; do
                log "DEBUG" "Deleting version $version of object $key"
                aws s3api --profile=$BBBPROFILE delete-object \
                    --bucket $SOURCE \
                    --key $key \
                    --version-id $version
            done
        done
    else
        log "WARN" "No S3 bucket found in stack $BBBPREPSTACK"
    fi
}

# Main execution starts here
log "INFO" "Starting BBB environment destruction"
log "INFO" "Using AWS Profile: $BBBPROFILE"
log "INFO" "##################################################"

# Clean ECR repositories first
clean_ecr_repositories

# Delete main BBB stack
log "INFO" "Deleting BBB Environment stack: $BBBSTACK"
if ! aws cloudformation delete-stack --profile=$BBBPROFILE --stack-name $BBBSTACK; then
    log "ERROR" "Failed to initiate deletion of stack $BBBSTACK"
fi

log "INFO" "Waiting for stack deletion to complete..."
if ! aws cloudformation wait stack-delete-complete --profile=$BBBPROFILE --stack-name $BBBSTACK; then
    log "ERROR" "Stack deletion failed or timed out"
fi
log "INFO" "BBB Environment stack deleted successfully"

# Clean S3 bucket
clean_s3_bucket

# Delete prerequisite stacks
BBBECRSTACK="${BBBSTACK}-Registry"
BBBPREPSTACK="${BBBSTACK}-Sources"

log "INFO" "Deleting ECR stack: $BBBECRSTACK"
if ! aws cloudformation delete-stack --stack-name $BBBECRSTACK --profile=$BBBPROFILE; then
    log "ERROR" "Failed to initiate deletion of ECR stack"
fi

log "INFO" "Deleting Sources stack: $BBBPREPSTACK"
if ! aws cloudformation delete-stack --stack-name $BBBPREPSTACK --profile=$BBBPROFILE; then
    log "ERROR" "Failed to initiate deletion of Sources stack"
fi

log "INFO" "Waiting for prerequisite stacks deletion to complete..."
if ! aws cloudformation wait stack-delete-complete --profile=$BBBPROFILE --stack-name $BBBECRSTACK; then
    log "WARN" "ECR stack deletion failed or timed out"
fi

if ! aws cloudformation wait stack-delete-complete --profile=$BBBPROFILE --stack-name $BBBPREPSTACK; then
    log "WARN" "Sources stack deletion failed or timed out"
fi

log "INFO" "BBB environment destruction completed successfully"
log "INFO" "Log file available at: $LOG_FILE"
exit 0
