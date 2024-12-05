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
    printf "%s [%s%s%s] %s\n" "$timestamp" "$color" "$level" "$NC" "$message"
    
    # Output to log file without color
    printf "%s [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
    
    # Exit on ERROR level messages
    if [ "$level" = "ERROR" ]; then
        exit 1
    fi
}

# Function to monitor CloudFormation stack events in real-time
monitor_stack() {
    local stack_name=$1
    local last_event_time
    last_event_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    log "DEBUG" "Starting stack monitoring for: $stack_name"
    
    while true; do
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
            --output text)
        
        if [[ ! $stack_status =~ .*IN_PROGRESS$ ]]; then
            if [[ $stack_status =~ .*FAILED$ || $stack_status =~ .*ROLLBACK.* ]]; then
                log "ERROR" "Stack deployment failed with status: $stack_status"
                return 1
            elif [[ $stack_status =~ .*COMPLETE$ ]]; then
                log "INFO" "Stack deployment completed successfully with status: $stack_status"
                return 0
            fi
        fi
        
        last_event_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        sleep 5
    done
}

# Modified deployment function
deploy_stack() {
    local stack_name=$1
    local template=$2
    shift 2
    local params=("$@")

    log "INFO" "Starting deployment for stack: $stack_name"
    log "DEBUG" "Using template: $template"
    
    if aws cloudformation deploy \
        --profile "$BBBPROFILE" \
        --stack-name "$stack_name" \
        "${params[@]}" \
        --template "$template" \
        --no-fail-on-empty-changeset; then
        
        monitor_stack "$stack_name"
        return $?
    else
        log "ERROR" "Failed to initiate stack deployment for $stack_name"
        return 1
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
if ! deploy_stack "$BBBPREPSTACK" \
    "./templates/bbb-on-aws-buildbuckets.template.yaml"; then
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

# Deploy registry stack
deploy_registry_stack() {
    log "INFO" "Deploying ECR registry stack..."
    BBBECRSTACK="${BBBSTACK}-registry"

    if ! deploy_stack "$BBBECRSTACK" \
        "./templates/bbb-on-aws-registry.template.yaml" \
        --capabilities CAPABILITY_IAM; then
        log "ERROR" "Failed to deploy ECR registry stack"
        return 1
    fi

    log "INFO" "ECR registry stack deployed successfully"
    return 0
}

# Deploy the registry stack
log "INFO" "Deploying ECR registry stack"
if ! deploy_registry_stack; then
    log "ERROR" "Failed to deploy ECR registry stack"
    exit 1
fi

# Get repository information and mirror images
log "INFO" "Getting repository information and mirroring images"
GREENLIGHTIMAGE=$(aws ecr describe-repositories --profile="$BBBPROFILE" --query 'repositories[?contains(repositoryName, `greenlight`)].repositoryName' --output text)
SCALELITEIMAGE=$(aws ecr describe-repositories --profile="$BBBPROFILE" --query 'repositories[?contains(repositoryName, `scalelite`)].repositoryName' --output text)

SCALELITEREGISTRY=$(aws ecr describe-repositories --profile="$BBBPROFILE" --query 'repositories[?contains(repositoryName, `scalelite`)].repositoryUri' --output text)
GREENLIGHTREGISTRY=$(aws ecr describe-repositories --profile="$BBBPROFILE" --query 'repositories[?contains(repositoryName, `greenlight`)].repositoryUri' --output text)

log "INFO" "##################################################"
log "INFO" "Mirror docker images to ECR for further usage"
log "INFO" "##################################################"

SCALELITEIMAGETAGS=("BBBScaleliteNginxImageTag" "BBBScaleliteApiImageTag" "BBBScalelitePollerImageTag" "BBBScaleliteImporterImageTag")
GREENLIGHTIMAGETAGS=("BBBgreenlightImageTag")

# Authenticate with ECR
if ! aws ecr get-login-password --profile="$BBBPROFILE" | docker login --username AWS --password-stdin "$SCALELITEREGISTRY"; then
    log "ERROR" "Failed to authenticate with Scalelite ECR registry"
fi
if ! aws ecr get-login-password --profile="$BBBPROFILE" | docker login --username AWS --password-stdin "$GREENLIGHTREGISTRY"; then
    log "ERROR" "Failed to authenticate with Greenlight ECR registry"
fi

# Process Scalelite images
for IMAGETAG in "${SCALELITEIMAGETAGS[@]}"
do
    TAGVALUE=$(jq -r ".Parameters.$IMAGETAG" bbb-on-aws-param.json)
    log "DEBUG" "Processing Scalelite image with tag: $TAGVALUE"
    docker pull --platform linux/amd64 "$SCALELITEIMAGE:$TAGVALUE"
    docker tag "$SCALELITEIMAGE:$TAGVALUE" "$SCALELITEREGISTRY:$TAGVALUE"
    docker push "$SCALELITEREGISTRY:$TAGVALUE"
done

# Process Greenlight images
for IMAGETAG in "${GREENLIGHTIMAGETAGS[@]}"
do
    TAGVALUE=$(jq -r ".Parameters.$IMAGETAG" bbb-on-aws-param.json)
    log "DEBUG" "Processing Greenlight image with tag: $TAGVALUE"
    docker pull --platform linux/amd64 "$GREENLIGHTIMAGE:$TAGVALUE"
    docker tag "$GREENLIGHTIMAGE:$TAGVALUE" "$GREENLIGHTREGISTRY:$TAGVALUE"
    docker push "$GREENLIGHTREGISTRY:$TAGVALUE"
done

log "INFO" "##################################################"
log "INFO" "Registry Preparation finished"
log "INFO" "##################################################"


# Final deployment
log "INFO" "Deploying main BBB infrastructure"
if ! deploy_stack "$BBBSTACK" \
    "./bbb-on-aws-root.template.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        "BBBOperatorEMail=$OPERATOREMAIL" \
        "BBBStackBucketStack=$BBBSTACK-Sources" \
        "BBBDomainName=$DOMAIN" \
        "BBBHostedZone=$HOSTEDZONE" \
        "BBBECRStack=$BBBSTACK-registry" \
        $(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' bbb-on-aws-param.json); then
    log "ERROR" "Main infrastructure deployment failed"
fi

# After your existing code, add:

# Set the initial admin password for the environment
log "INFO" "Setting the initial admin password"
log "INFO" "##################################################"

# Get the secrets
log "DEBUG" "Retrieving administrator credentials from Secrets Manager"
ADMIN_SECRET=$(aws secretsmanager list-secrets \
    --profile "$BBBPROFILE" \
    --filter Key="name",Values="BBBAdministratorlogin" \
    --query 'SecretList[0].Name' \
    --output text)

if [ -z "$ADMIN_SECRET" ]; then
    log "ERROR" "Failed to retrieve admin secret from Secrets Manager"
fi

ADMIN_AUTH=$(aws secretsmanager get-secret-value \
    --profile "$BBBPROFILE" \
    --secret-id "$ADMIN_SECRET")

if [ -z "$ADMIN_AUTH" ]; then
    log "ERROR" "Failed to retrieve admin authentication values"
fi

ADMIN_PASSWORD=$(echo "$ADMIN_AUTH" | jq -r '.SecretString | fromjson | .password')
ADMIN_LOGIN=$(echo "$ADMIN_AUTH" | jq -r '.SecretString | fromjson | .username')

# Get the cluster information
log "DEBUG" "Retrieving ECS cluster information"
ECS_CLUSTERS=$(aws ecs --profile="$BBBPROFILE" list-clusters)
ECS_CLUSTER=$(echo "$ECS_CLUSTERS" | jq -r '.clusterArns[0] | split("/") | .[1]')

if [ -z "$ECS_CLUSTER" ]; then
    log "ERROR" "Failed to retrieve ECS cluster information"
fi

# Get Greenlight service and task
log "DEBUG" "Retrieving Greenlight service information"
GREENLIGHT_SERVICE=$(aws ecs list-services \
    --profile "$BBBPROFILE" \
    --cluster "$ECS_CLUSTER" \
    --query "serviceArns[?contains(@, 'BBBgreenlightService')]" \
    --output text | xargs -n 1 basename)

if [ -z "$GREENLIGHT_SERVICE" ]; then
    log "ERROR" "Failed to retrieve Greenlight service"
fi

log "DEBUG" "Retrieving Greenlight task information"
GREENLIGHT_TASK=$(aws ecs list-tasks \
    --profile "$BBBPROFILE" \
    --cluster "$ECS_CLUSTER" \
    --service "$GREENLIGHT_SERVICE" \
    --output text | awk -F"/" '{print $NF}' | rev | awk -F"/" '{print $1}' | rev)

if [ -z "$GREENLIGHT_TASK" ]; then
    log "ERROR" "Failed to retrieve Greenlight task"
fi

# Execute the admin creation command
log "INFO" "Creating admin user in Greenlight"
if ! aws ecs execute-command \
    --profile="$BBBPROFILE" \
    --cluster "$ECS_CLUSTER" \
    --task "$GREENLIGHT_TASK" \
    --container greenlight \
    --interactive \
    --command "bundle exec rake admin:create[\"bbbadmin\",\"${ADMIN_LOGIN}\",\"${ADMIN_PASSWORD}\"]"; then
    
    log "ERROR" "Failed to create admin user in Greenlight"
fi

log "INFO" "Admin user creation process completed"
log "INFO" "##################################################"

log "INFO" "Deployment completed successfully"
log "INFO" "Log file available at: $LOG_FILE"
exit 0
