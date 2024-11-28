#!/bin/sh
# BBB Application Infrastructure deployment script
# Author: David Surey - suredavi@amazon.de
# Disclaimer: NOT FOR PRODUCTION USE - Only for demo and testing purposes

# Color codes for output formatting
# Using printf to ensure proper escape sequence interpretation
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
NC=$(printf '\033[0m')

# Logging configuration
LOG_LEVEL=${LOG_LEVEL:-"INFO"}  # Default to INFO if not set
LOG_FILE="/tmp/bbb-setup-$(date +%Y%m%d-%H%M%S).log"

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
    echo "Usage: $0 -p <aws-profile> -e <operator-email> -h <hosted-zone> -s <stack-name> -d <domain-name>"
    echo "Options:"
    echo "  -p : AWS Profile"
    echo "  -e : Operator Email"
    echo "  -h : Hosted Zone"
    echo "  -s : Stack Name"
    echo "  -d : Domain Name"
    echo "  -l : Log Level (DEBUG|INFO|WARN|ERROR) - default: INFO"
    exit 1
}

# Initialize variables
BBBPROFILE=""
OPERATOREMAIL=""
HOSTEDZONE=""
BBBSTACK=""
DOMAIN=""

# Parse command line arguments
while getopts "p:e:h:s:d:l:" opt; do
    case $opt in
        p) BBBPROFILE="$OPTARG" ;;
        e) OPERATOREMAIL="$OPTARG" ;;
        h) HOSTEDZONE="$OPTARG" ;;
        s) BBBSTACK="$OPTARG" ;;
        d) DOMAIN="$OPTARG" ;;
        l) 
            case $OPTARG in
                DEBUG|INFO|WARN|ERROR) LOG_LEVEL="$OPTARG" ;;
                *) log "ERROR" "Invalid log level: $OPTARG. Valid levels are: DEBUG INFO WARN ERROR" ;;
            esac
            ;;
        *) log "ERROR" "Invalid option -$OPTARG" ;;
    esac
done

# Validate all required parameters
log "DEBUG" "Validating input parameters..."
validate_input "AWS Profile" "$BBBPROFILE"
validate_input "Operator Email" "$OPERATOREMAIL"
validate_input "Hosted Zone" "$HOSTEDZONE"
validate_input "Stack Name" "$BBBSTACK"
validate_input "Domain" "$DOMAIN"

# Validate email format using grep
if ! echo "$OPERATOREMAIL" | grep -E "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$" > /dev/null; then
    log "ERROR" "Invalid email format: $OPERATOREMAIL"
fi

# Check for required tools
log "DEBUG" "Checking required tools..."
if ! command -v aws > /dev/null 2>&1; then
    log "ERROR" "aws CLI is not installed"
fi

if ! docker ps > /dev/null 2>&1; then
    log "ERROR" "Docker is not running or not installed"
fi

if ! command -v jq > /dev/null 2>&1; then
    log "ERROR" "jq is not installed"
fi

# Main execution starts here
log "INFO" "Starting BBB deployment with AWS Profile: $BBBPROFILE"
log "INFO" "##################################################"

# Deploy Prerequisites
log "INFO" "Deploying Prerequisites for BBB Environment"
BBBPREPSTACK="${BBBSTACK}-Sources"
if ! aws cloudformation deploy --stack-name "$BBBPREPSTACK" \
    --profile="$BBBPROFILE" \
    --template ./templates/bbb-on-aws-buildbuckets.template.yaml; then
    log "ERROR" "Failed to deploy prerequisites stack"
fi
log "INFO" "Prerequisites deployment completed"

# Get source bucket
SOURCE=$(aws cloudformation describe-stack-resources \
    --profile "$BBBPROFILE" \
    --stack-name "$BBBPREPSTACK" \
    --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
    --output text)

log "DEBUG" "Source bucket: $SOURCE"

# Copy files to S3
log "INFO" "Copying files to S3 bucket"
if [ -d "./templates" ] && [ -d "./scripts" ]; then
    log "DEBUG" "Syncing templates and scripts to S3"
    aws s3 sync --profile="$BBBPROFILE" --exclude=".DS_Store" ./templates "s3://$SOURCE"
    aws s3 sync --profile="$BBBPROFILE" --exclude=".DS_Store" ./scripts "s3://$SOURCE"
else
    log "ERROR" "Required source directories (templates/ or scripts/) are missing"
fi

# Environment type check
ENVIRONMENTTYPE=$(jq -r ".Parameters.BBBEnvironmentType" bbb-on-aws-param.json)
log "DEBUG" "Environment type: $ENVIRONMENTTYPE"

if [ "$ENVIRONMENTTYPE" = "scalable" ]; then
    log "INFO" "Setting up scalable environment components"
fi

# Final deployment
log "INFO" "Deploying main BBB infrastructure"
if ! aws cloudformation deploy \
    --profile="$BBBPROFILE" \
    --stack-name "$BBBSTACK" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        "BBBOperatorEMail=$OPERATOREMAIL" \
        "BBBStackBucketStack=$BBBSTACK-Sources" \
        "BBBDomainName=$DOMAIN" \
        "BBBHostedZone=$HOSTEDZONE" \
        "BBBECRStack=$BBBSTACK-Registry" \
    $(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' bbb-on-aws-param.json) \
    --template ./bbb-on-aws-root.template.yaml; then
    log "ERROR" "Main infrastructure deployment failed"
fi

log "INFO" "Deployment completed successfully"
log "INFO" "Log file available at: $LOG_FILE"
exit 0
