#!/bin/bash
# BigBlueButton Application Bootstrap Script
# This script initializes and configures a BigBlueButton instance with scalable components

# Exit on error
set -e

# Log file location
LOG_FILE="/var/log/bbb-bootstrap.log"

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
LOG_LEVEL="DEBUG"

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

# Function to get EC2 metadata with IMDSv2 token
get_metadata() {
    local metadata_path=$1
    local token
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log "DEBUG" "Requesting IMDSv2 token (attempt $attempt of $max_attempts)..." >&2
        token=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
            -s -f 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$token" ]; then
            log "DEBUG" "Token received successfully" >&2
            log "DEBUG" "Requesting metadata: $metadata_path" >&2
            
            local result=$(curl -H "X-aws-ec2-metadata-token: $token" \
                -s -f "http://169.254.169.254/latest/meta-data/${metadata_path}" 2>/dev/null)

            if [ $? -eq 0 ] && [ -n "$result" ]; then
                log "DEBUG" "Successfully retrieved metadata" >&2
                echo "$result"
                return 0
            else
                log "WARN" "Failed to get metadata, attempt $attempt" >&2
            fi
        else
            log "WARN" "Failed to get token, attempt $attempt" >&2
        fi

        attempt=$((attempt + 1))
        [ $attempt -le $max_attempts ] && sleep 5
    done

    log "ERROR" "Failed to get metadata after $max_attempts attempts" >&2
    return 1
}


# Function to install CloudWatch agent
install_cloudwatch_agent() {
    log "INFO" "Installing CloudWatch agent"
    
    if ! wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb; then
        log "ERROR" "Failed to download CloudWatch agent"
        return 1
    fi
    
    if ! dpkg -i -E ./amazon-cloudwatch-agent.deb; then
        log "ERROR" "Failed to install CloudWatch agent"
        return 1
    fi
    
    rm -f ./amazon-cloudwatch-agent.deb
    
    # Verify version
    local version=$(/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -version)
    log "INFO" "CloudWatch agent version ${version} installed successfully"
}

# Function to configure CloudWatch users and permissions
configure_cloudwatch_users() {
    log "INFO" "Configuring CloudWatch users and permissions..."
    
    # Add MongoDB user and configure groups
    useradd mongodb || log "WARN" "MongoDB user already exists"
    usermod -a -G adm cwagent || log "ERROR" "Failed to add cwagent to adm group"
    usermod -a -G mongodb cwagent || log "ERROR" "Failed to add cwagent to mongodb group"
    usermod -a -G mongodb mongodb || log "ERROR" "Failed to add mongodb to mongodb group"
    
    # Setup MongoDB logging
    mkdir -p /var/log/mongodb
    touch /var/log/mongodb/mongod.log
    chown -R mongodb:mongodb /var/log/mongodb
    chmod g+r /var/log/mongodb/mongod.log
    
    log "INFO" "CloudWatch users and permissions configured"
}

# Function to configure CloudWatch agent
configure_cloudwatch_agent() {
    local bucket=$1
    local logs_group=$2
    
    log "INFO" "Configuring CloudWatch agent..."
    
    if aws s3 cp "s3://${bucket}/bbb-cwagent-config.json" /tmp/bbb-cwagent-config.json; then
        log "DEBUG" "CloudWatch config downloaded successfully"
        
        sed -i "s|SYSTEMLOGS_PLACEHOLDER|${logs_group}|g" /tmp/bbb-cwagent-config.json
        sed -i "s|APPLICATIONLOGS_PLACEHOLDER|${logs_group}|g" /tmp/bbb-cwagent-config.json
        
        if sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/tmp/bbb-cwagent-config.json; then
            log "INFO" "CloudWatch agent configured successfully"
        else
            log "ERROR" "Failed to configure CloudWatch agent"
            return 1
        fi
    else
        log "ERROR" "Failed to download CloudWatch config from S3"
        return 1
    fi
}

# Function to install required packages
install_required_packages() {
    log "INFO" "Installing required packages..."
    
    if pip3 install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz; then
        log "DEBUG" "AWS CFN bootstrap installed successfully"
    else
        log "ERROR" "Failed to install AWS CFN bootstrap"
        return 1
    fi
}
# Function to install and configure EFS utils
install_efs_utils() {
    log "INFO" "Installing EFS utilities..."
    
    cd /tmp
    if git clone https://github.com/aws/efs-utils; then
        cd efs-utils
        if ./build-deb.sh; then
            if apt -y install ./build/amazon-efs-utils*deb; then
                log "INFO" "EFS utils installed successfully"
                cd /tmp && rm -rf /tmp/efs-utils
            else
                log "ERROR" "Failed to install EFS utils package"
                return 1
            fi
        else
            log "ERROR" "Failed to build EFS utils"
            return 1
        fi
    else
        log "ERROR" "Failed to clone EFS utils repository"
        return 1
    fi
}

# Function to configure instance hostname
configure_hostname() {
    log "INFO" "Configuring instance hostname..."
    
    # Get instance IP using IMDSv2
    local instance_ipv4
    instance_ipv4=$(get_metadata "public-ipv4")
    if [ $? -ne 0 ] || [ -z "$instance_ipv4" ]; then
        log "ERROR" "Failed to get instance IP address"
        return 1
    fi
    log "DEBUG" "Retrieved instance IP: ${instance_ipv4}"

    # Generate random hostname suffix
    local instance_random
    instance_random=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)
    log "DEBUG" "Generated random suffix: ${instance_random}"

    # Set hostname variables
    local instance_publichostname="vc-${instance_random}"
    local instance_fqdn="${instance_publichostname}.${BBBDomainName}"
    log "INFO" "Generated FQDN: ${instance_fqdn}"

    # Store instance information
    echo "${instance_ipv4}" > /tmp/instance_ipv4
    echo "${instance_fqdn}" > /tmp/instance_fqdn
    echo "${instance_publichostname}" > /tmp/instance_publichostname

    # Set system hostname
    log "DEBUG" "Setting system hostname to: ${instance_fqdn}"
    hostnamectl set-hostname "${instance_fqdn}"
    
    # Update hosts file
    log "DEBUG" "Updating /etc/hosts with new hostname"
    echo "${instance_ipv4} ${instance_fqdn} ${instance_publichostname}" >> /etc/hosts
}

# Function to setup Route53 handler
setup_route53_handler() {
    log "INFO" "Setting up Route53 handler..."

    # Install cli53
    log "DEBUG" "Installing cli53..."
    if ! wget --tries=10 --timeout=20 https://github.com/barnybug/cli53/releases/download/0.8.22/cli53-linux-amd64 -O /usr/local/bin/cli53; then
        log "ERROR" "Failed to download cli53"
        return 1
    fi
    chmod +x /usr/local/bin/cli53

    # Setup Route53 handler service
    log "DEBUG" "Setting up Route53 handler service..."
    if ! aws s3 cp "s3://${BBBStackBucketStack}/route53-handler.service" /etc/systemd/system/route53-handler.service; then
        log "ERROR" "Failed to download Route53 handler service file"
        return 1
    fi

    if ! aws s3 cp "s3://${BBBStackBucketStack}/route53-handler.sh" /usr/local/bin/route53-handler.sh; then
        log "ERROR" "Failed to download Route53 handler script"
        return 1
    fi
    chmod +x /usr/local/bin/route53-handler.sh

    # Configure Route53 handler
    local instance_publichostname=$(cat /tmp/instance_publichostname)
    sed -i "s/INSTANCE_PLACEHOLDER/${instance_publichostname}/g" /etc/systemd/system/route53-handler.service
    sed -i "s/ZONE_PLACEHOLDER/${BBBHostedZone}/g" /etc/systemd/system/route53-handler.service

    # Enable and start Route53 handler service
    systemctl daemon-reload
    if ! systemctl enable route53-handler; then
        log "ERROR" "Failed to enable Route53 handler service"
        return 1
    fi
    if ! systemctl start route53-handler; then
        log "ERROR" "Failed to start Route53 handler service"
        return 1
    fi
    
    log "INFO" "Route53 handler setup completed"
}

# Function to setup storage
setup_storage() {
    log "INFO" "Setting up storage..."

    # Setup shared storage
    mkdir -p /mnt/bbb-recordings
    local efs_mount_entry="${BBBSharedStorageFS}: /mnt/bbb-recordings efs defaults,_netdev,tls,iam,accesspoint=${BBBSharedStorageAPspool},rw 0 0"
    log "DEBUG" "Adding EFS mount entry: ${efs_mount_entry}"
    echo "${efs_mount_entry}" >> /etc/fstab

    # Setup BigBlueButton directory
    mkdir -p /var/bigbluebutton

    # Setup device storage
    local DEVICE
    if test -e "/dev/nvme1n1"; then
        DEVICE="/dev/nvme1n1"
        log "DEBUG" "Using NVMe device: ${DEVICE}"
        setup_nvme_storage "$DEVICE"
    else
        DEVICE="/dev/sdf"
        log "DEBUG" "Using standard device: ${DEVICE}"
        setup_standard_storage "$DEVICE"
    fi

    # Mount all filesystems
    log "DEBUG" "Mounting all filesystems..."
    if ! mount -a; then
        log "ERROR" "Failed to mount all filesystems"
        return 1
    fi
    
    log "INFO" "Storage setup completed successfully"
}

# Function to setup NVMe storage
setup_nvme_storage() {
    local DEVICE=$1
    log "DEBUG" "Setting up NVMe storage on ${DEVICE}"
    
    if ! parted -s -a optimal -- "$DEVICE" mklabel gpt mkpart primary 1MiB -2048s; then
        log "ERROR" "Failed to partition NVMe device"
        return 1
    fi
    
    sleep 20s
    if ! mkfs.ext4 -F "${DEVICE}p1"; then
        log "ERROR" "Failed to create filesystem on NVMe device"
        return 1
    fi
    
    local UUID=$(blkid | grep "${DEVICE}p1" | awk '{print $2}' | sed 's/"//g')
    echo "$UUID       /var/bigbluebutton   ext4    defaults,nofail        0       2" >> /etc/fstab
}

# Function to setup standard storage
setup_standard_storage() {
    local DEVICE=$1
    log "DEBUG" "Setting up standard storage on ${DEVICE}"
    
    if ! parted -s -a optimal -- "$DEVICE" mklabel gpt mkpart primary 1MiB -2048s; then
        log "ERROR" "Failed to partition standard device"
        return 1
    fi
    
    sleep 20s
    if ! mkfs.ext4 -F "${DEVICE}1"; then
        log "ERROR" "Failed to create filesystem on standard device"
        return 1
    fi
    
    local UUID=$(blkid | grep "${DEVICE}1" | awk '{print $2}' | sed 's/"//g')
    echo "$UUID       /var/bigbluebutton   ext4    defaults,nofail        0       2" >> /etc/fstab
}

# Function to wait for DNS propagation
wait_for_dns() {
    local instance_fqdn=$(cat /tmp/instance_fqdn)
    local instance_ipv4=$(cat /tmp/instance_ipv4)
    log "INFO" "Waiting for DNS propagation for ${instance_fqdn}..."
    
    local max_attempts=30
    local attempt=1
    local wait_time=20
    
    while [ $attempt -le $max_attempts ]; do
        log "DEBUG" "DNS check attempt $attempt of $max_attempts"
        
        if [ "$(dig +short "$instance_fqdn")" = "$instance_ipv4" ]; then
            log "INFO" "DNS propagation completed successfully"
            return 0
        fi
        
        log "DEBUG" "Waiting ${wait_time} seconds for DNS propagation..."
        sleep $wait_time
        attempt=$((attempt + 1))
    done
    
    log "ERROR" "DNS propagation timed out after $((max_attempts * wait_time)) seconds"
    return 1
}

# Function to install BigBlueButton
install_bbb() {
    local instance_fqdn=$(cat /tmp/instance_fqdn)
    log "INFO" "Installing BigBlueButton version ${BBBApplicationVersion}..."
    
    local formatted_version=$(echo "$BBBApplicationVersion" | sed 's/focal-//' | sed 's/\([0-9]\)\([0-9]\)\([0-9]\)/\1.\2/')
    # Convert version number (e.g., 2.7.0) to URI format (v2.7.x-release)
    local bbb_uri_version="v${formatted_version}.x-release"
    
    log "DEBUG" "Using BBB install script from branch: ${bbb_uri_version}"
    
    # Install BBB using the correct version format
    if ! wget -qO- "https://raw.githubusercontent.com/bigbluebutton/bbb-install/${bbb_uri_version}/bbb-install.sh" | bash -s -- -v "${BBBApplicationVersion}" -s "${instance_fqdn}" -e "${BBBOperatorEmail}" -j; then
        log "ERROR" "Failed to install BBB"
        return 1
    fi
    
    log "INFO" "BBB installation completed successfully"
    
    # Verify installation
    if ! bbb-conf --check | tee /var/log/bbb-install-check.log; then
        log "WARN" "BBB installation verification showed warnings, check /var/log/bbb-install-check.log"
    fi
}


check_and_reinstall_bbb() {
    local instance_fqdn=$(cat /tmp/instance_fqdn)
    local cert_dir="/etc/letsencrypt/live/${instance_fqdn}"
    local formatted_version=$(echo "$BBBApplicationVersion" | sed 's/focal-//' | sed 's/\([0-9]\)\([0-9]\)\([0-9]\)/\1.\2/')
    local bbb_uri_version="v${formatted_version}.x-release"
    local max_attempts=5
    local attempt=1
    local wait_time=30  # 0.5 minutes in seconds

    # Function to check installation status
    check_installation() {
        # Check if certificate directory exists and is not empty
        if [ ! -d "$cert_dir" ] || [ -z "$(ls -A $cert_dir 2>/dev/null)" ]; then
            log "WARN" "Let's Encrypt certificate directory missing or empty for ${instance_fqdn}"
            return 1
        fi

        # Check if nginx is listening on port 443
        if ! netstat -tuln | grep -q ':443 '; then
            log "WARN" "Nginx not listening on port 443"
            return 1
        fi

        return 0
    }

    # Initial check
    if check_installation; then
        log "INFO" "BBB installation appears to be correct"
        return 0
    fi

    log "WARN" "Installation issues detected, starting reinstallation loop"

    # Installation loop
    while [ $attempt -le $max_attempts ]; do
        log "INFO" "Installation attempt $attempt of $max_attempts"
        
        # Wait before attempting installation
        log "INFO" "Waiting ${wait_time} seconds before attempt..."
        for i in $(seq $wait_time -60 1); do
            if [ $i -gt 0 ]; then
                log "INFO" "$(($i / 60)) minutes remaining before next attempt..."
                sleep 60
            fi
        done

        log "INFO" "Starting BBB installation..."
        
        # Run the installer
        wget -qO- "https://raw.githubusercontent.com/bigbluebutton/bbb-install/${bbb_uri_version}/bbb-install.sh" | \
        bash -s -- -v "${BBBApplicationVersion}" -s "${instance_fqdn}" -e "${BBBOperatorEmail}" -j -l 2>&1 | \
        tee /tmp/bbb-install.log | while IFS= read -r line; do
            if echo "$line" | grep -i "let's encrypt" > /dev/null; then
                log "INFO" "Let's Encrypt: $line"
            fi
            echo "$line"
        done

        # Check if installation was successful
        if check_installation; then
            log "INFO" "BBB installation successful on attempt $attempt"
            return 0
        fi

        log "WARN" "Installation attempt $attempt failed"
        attempt=$((attempt + 1))
    done

    log "ERROR" "Failed to install BBB after $max_attempts attempts"
    return 1
}

# Function to setup Scalelite
setup_scalelite() {
    log "INFO" "Setting up Scalelite..."

    # Create scalelite group
    groupadd -g 2000 scalelite-spool || log "WARN" "Group scalelite-spool already exists"
    usermod -a -G scalelite-spool bigbluebutton

    # Download Scalelite scripts
    local SCRIPTS=(
        "scalelite_post_publish.rb"
        "scalelite_batch_import.sh"
    )
    
    for script in "${SCRIPTS[@]}"; do
        log "DEBUG" "Downloading ${script}..."
        if ! wget --tries=10 --timeout=20 "https://raw.githubusercontent.com/blindsidenetworks/scalelite/master/bigbluebutton/${script}" \
            -O "/usr/local/bigbluebutton/core/scripts/post_publish/${script}"; then
            log "ERROR" "Failed to download ${script}"
            return 1
        fi
    done

    # Set permissions
    chmod +x /usr/local/bigbluebutton/core/scripts/post_publish/*.{rb,sh}

    # Setup daily cron
    if ! wget --tries=10 --timeout=20 "https://raw.githubusercontent.com/blindsidenetworks/scalelite/master/bigbluebutton/scalelite_prune_recordings" \
            -O "/etc/cron.daily/scalelite_prune_recordings"; then
            log "ERROR" "Failed to download scalelite_prune_recordings"
            return 1
    fi
    chmod +x /etc/cron.daily/scalelite_prune_recordings

    # Download and configure Scalelite config
    if ! aws s3 cp "s3://${BBBStackBucketStack}/scalelite-config.yml" /usr/local/bigbluebutton/core/scripts/scalelite.yml; then
        log "ERROR" "Failed to download Scalelite config"
        return 1
    fi

    # Install required packages
    log "DEBUG" "Installing required packages..."
    if ! apt-get -y install ruby-dev libsystemd-dev; then
        log "ERROR" "Failed to install required system packages"
        return 1
    fi
    
    if ! gem install redis builder nokogiri:1.15.7 loofah open4 absolute_time journald-logger; then
        log "ERROR" "Failed to install required gems"
        return 1
    fi

    setup_scalelite_handler
}

# Function to setup Scalelite handler
setup_scalelite_handler() {
    log "INFO" "Setting up Scalelite handler..."

    # Download handler files
    if ! aws s3 cp "s3://${BBBStackBucketStack}/scalelite-handler.service" /etc/systemd/system/scalelite-handler.service; then
        log "ERROR" "Failed to download Scalelite handler service file"
        return 1
    fi

    if ! aws s3 cp "s3://${BBBStackBucketStack}/scalelite-handler.sh" /usr/local/bin/scalelite-handler.sh; then
        log "ERROR" "Failed to download Scalelite handler script"
        return 1
    fi
    chmod +x /usr/local/bin/scalelite-handler.sh

    # Get BBB credentials
    local SERVER
    local SECRET
    SERVER="$(bbb-conf --secret | head -2 | tail -1 | sed -r 's/.*URL: //g')api"
    SECRET=$(bbb-conf --secret | head -3 | tail -1 | sed -r 's/.*Secret: //g')

    if [ -z "$SERVER" ] || [ -z "$SECRET" ]; then
        log "ERROR" "Failed to get BBB credentials"
        return 1
    fi

    # Configure handler service
    log "DEBUG" "Configuring Scalelite handler service..."
    sed -i "s/SECRET_PLACEHOLDER/${SECRET}/g" /etc/systemd/system/scalelite-handler.service
    sed -i "s|SERVER_PLACEHOLDER|${SERVER}|g" /etc/systemd/system/scalelite-handler.service
    sed -i "s/AWSREGION_PLACEHOLDER/${AWSRegion}/g" /etc/systemd/system/scalelite-handler.service
    sed -i "s/ECSCLUSTER_PLACEHOLDER/${BBBECSCluster}/g" /etc/systemd/system/scalelite-handler.service
    sed -i "s/ECSMODE_PLACEHOLDER/${BBBECSInstanceType}/g" /etc/systemd/system/scalelite-handler.service
    sed -i "s/TASKSUBNETS_PLACEHOLDER/${BBBApplicationSubnet}/g" /etc/systemd/system/scalelite-handler.service
    sed -i "s/TASKSGS_PLACEHOLDER/${BBBECSTaskSecurityGroup}/g" /etc/systemd/system/scalelite-handler.service

    # Enable and start handler service
    systemctl daemon-reload
    if ! systemctl enable scalelite-handler; then
        log "ERROR" "Failed to enable Scalelite handler service"
        return 1
    fi
    if ! systemctl start scalelite-handler; then
        log "ERROR" "Failed to start Scalelite handler service"
        return 1
    fi
    
    log "INFO" "Scalelite handler setup completed successfully"
}

# Parse command line arguments
while getopts ":a:b:c:e:g:h:i:j:k:l:m:n:o:d" opt; do
    case $opt in
        a) BBBStackBucketStack="${OPTARG}"
           log "DEBUG" "Stack bucket parameter received: ${OPTARG}"
        ;;
        b) BBBSystemLogsGroup="${OPTARG}"
           log "DEBUG" "System logs group parameter received: ${OPTARG}"
        ;;
        c) BBBDomainName="${OPTARG}"
           log "DEBUG" "Domain name parameter received: ${OPTARG}"
        ;;
        e) BBBHostedZone="${OPTARG}"
           log "DEBUG" "Hosted zone parameter received: ${OPTARG}"
        ;;
        g) BBBOperatorEMail="${OPTARG}"
           log "DEBUG" "Operator email parameter received: ${OPTARG}"
        ;;
        h) BBBApplicationVersion="${OPTARG}"
           log "DEBUG" "Application version parameter received: ${OPTARG}"
        ;;
        i) AWSRegion="${OPTARG}"
           log "DEBUG" "AWS region parameter received: ${OPTARG}"
        ;;
        j) BBBSharedStorageFS="${OPTARG}"
           log "DEBUG" "Shared storage FS parameter received: ${OPTARG}"
        ;;
        k) BBBSharedStorageAPspool="${OPTARG}"
           log "DEBUG" "Shared storage AP spool parameter received: ${OPTARG}"
        ;;
        l) BBBECSCluster="${OPTARG}"
           log "DEBUG" "ECS cluster parameter received: ${OPTARG}"
        ;;
        m) BBBECSInstanceType="${OPTARG}"
           log "DEBUG" "ECS instance type parameter received: ${OPTARG}"
        ;;
        n) BBBApplicationSubnet="${OPTARG}"
           log "DEBUG" "Application subnet parameter received: ${OPTARG}"
        ;;
        o) BBBECSTaskSecurityGroup="${OPTARG}"
           log "DEBUG" "ECS task security group parameter received: ${OPTARG}"
        ;;
        d) LOG_LEVEL="DEBUG"
           log "DEBUG" "Debug mode enabled"
        ;;
        \?) log "ERROR" "Invalid option -$OPTARG"
            exit 1
        ;;
    esac
done

# Main execution flow
main() {
    log "INFO" "Starting BBB bootstrap process..."

    # Check required parameters
    local required_params=(
        "BBBStackBucketStack"
        "BBBSystemLogsGroup"
        "BBBDomainName"
        "BBBHostedZone"
        "BBBOperatorEMail"
        "BBBApplicationVersion"
        "AWSRegion"
        "BBBSharedStorageFS"
        "BBBSharedStorageAPspool"
        "BBBECSCluster"
        "BBBECSInstanceType"
        "BBBApplicationSubnet"
        "BBBECSTaskSecurityGroup"
    )

    for param in "${required_params[@]}"; do
        if [ -z "${!param}" ]; then
            log "ERROR" "Missing required parameter: $param"
            return 1
        fi
    done

    # Execute installation steps
    local steps=(
        "install_cloudwatch_agent"
        "configure_cloudwatch_users"
        "configure_cloudwatch_agent"
        "install_required_packages"
        "install_efs_utils"
        "configure_hostname"
        "setup_route53_handler"
        "setup_storage"
        "wait_for_dns"
        "install_bbb"
        "wait_for_dns"
        "check_and_reinstall_bbb"
        "setup_scalelite"
    )

    for step in "${steps[@]}"; do
        log "INFO" "Executing step: $step"
        if ! $step "$BBBStackBucketStack" "$BBBSystemLogsGroup"; then
            log "ERROR" "Step failed: $step"
            return 1
        fi
    done

    log "INFO" "BBB bootstrap process completed successfully"
    return 0
}

# Check log file permissions and rotate if needed
rotate_log

# Execute main function
if ! main; then
    log "ERROR" "Bootstrap process failed"
    exit 1
fi

exit 0