#!/bin/bash

while getopts ":a:b:c:d:e:f:g:h:i:" opt; do
  case $opt in
    a) BBBStackBucketStack="$OPTARG"
    ;;
    b) BBBSystemLogsGroup="$OPTARG"
    ;;
    c) BBBDomainName="$OPTARG"
    ;;
    d) BBBTurnHostnameParameter="$OPTARG"
    ;;
    e) BBBHostedZone="$OPTARG"
    ;;
    f) BBBTurnSecret="$OPTARG"
    ;;
    g) BBBOperatorEMail="$OPTARG"
    ;;  
    h) BBBApplicationVersion="$OPTARG"
    ;;
    i) AWSRegion="$OPTARG"
    ;;                   
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done

wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E ./amazon-cloudwatch-agent.deb

# Adding cwagent user to all required groups
useradd mongodb
usermod -a -G adm cwagent
usermod -a -G mongodb cwagent
usermod -a -G mongodb mongodb
mkdir /var/log/mongodb
touch /var/log/mongodb/mongod.log
chown -R mongodb:mongodb /var/log/mongodb
chmod g+r /var/log/mongodb/mongod.log

aws s3 cp s3://$BBBStackBucketStack/bbb-cwagent-config.json /tmp/bbb-cwagent-config.json
sed -i "s|SYSTEMLOGS_PLACEHOLDER|$BBBSystemLogsGroup|g" /tmp/bbb-cwagent-config.json
sed -i "s|APPLICATIONLOGS_PLACEHOLDER|$BBBSystemLogsGroup|g" /tmp/bbb-cwagent-config.json
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/tmp/bbb-cwagent-config.json

pip3 install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz

# Set instance Hostname
instance_ipv4=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
instance_random=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)
instance_publichostname=vc-$instance_random
instance_fqdn=$instance_publichostname.$BBBDomainName

# register in route53
wget --tries=10 https://github.com/barnybug/cli53/releases/download/0.8.18/cli53-linux-amd64 -O /usr/local/bin/cli53
sudo chmod +x /usr/local/bin/cli53

# create script for route53-handler
aws s3 cp s3://$BBBStackBucketStack/route53-handler.service /etc/systemd/system/route53-handler.service
aws s3 cp s3://$BBBStackBucketStack/route53-handler.sh /usr/local/bin/route53-handler.sh
chmod +x /usr/local/bin/route53-handler.sh

sed -i "s/INSTANCE_PLACEHOLDER/$instance_publichostname/g" /etc/systemd/system/route53-handler.service
sed -i "s/ZONE_PLACEHOLDER/$BBBHostedZone/g" /etc/systemd/system/route53-handler.service

systemctl daemon-reload
systemctl enable route53-handler
systemctl start route53-handler

mkdir -p /var/bigbluebutton

if test -e "/dev/nvme1n1"; then
  DEVICE=/dev/nvme1n1
  parted -s -a optimal -- $DEVICE mklabel gpt mkpart primary 1MiB -2048s
  sleep 20s
  mkfs.ext4 -F $DEVICE\p1
  UUID=$(blkid |grep "$DEVICE\p1" | awk '{print $2}' |sed 's/"//g')
else
  DEVICE=/dev/sdf
  parted -s -a optimal -- $DEVICE mklabel gpt mkpart primary 1MiB -2048s
  sleep 20s
  mkfs.ext4 -F $DEVICE\1
  UUID=$(blkid |grep "$DEVICE\1" | awk '{print $2}' |sed 's/"//g')
fi

echo "$UUID       /var/bigbluebutton   ext4    defaults,nofail        0       2" >> /etc/fstab
mount -a

turn_hostname=$(aws ssm get-parameter --region $AWSRegion --name "$BBBTurnHostnameParameter" --with-decryption --output text --query Parameter.Value)
turn_fqdn=$turn_hostname.$BBBDomainName
turnsecret=$(aws secretsmanager get-secret-value --region $AWSRegion --secret-id $BBBTurnSecret --query SecretString --output text | jq -r .turnkeyvalue)

sleep 1m

x=1
while [ $x -le 5 ]
do
  until host $instance_fqdn  | grep -m 1 "has address $instance_ipv4"; do sleep 5 ; done
  x=$(( $x + 1 ))
done

if [[ $BBBApplicationVersion == *"25"* ]]; then
  wget -qO- https://ubuntu.bigbluebutton.org/bbb-install-2.5.sh | bash -s -- -v $BBBApplicationVersion -s $instance_fqdn -e $BBBOperatorEMail -c $turn_fqdn:$turnsecret -j
elif [[ $BBBApplicationVersion == *"26"* ]]; then
  wget -qO- https://ubuntu.bigbluebutton.org/bbb-install-2.6.sh | bash -s -- -v $BBBApplicationVersion -s $instance_fqdn -e $BBBOperatorEMail -c $turn_fqdn:$turnsecret -j
elif [[ $BBBApplicationVersion == *"27"* ]]; then
  wget -qO- https://ubuntu.bigbluebutton.org/bbb-install-2.7.sh | bash -s -- -v $BBBApplicationVersion -s $instance_fqdn -e $BBBOperatorEMail -c $turn_fqdn:$turnsecret -j  
fi

# create script for turn-handler
aws s3 cp s3://$BBBStackBucketStack/turn-handler.service /etc/systemd/system/turn-handler.service
aws s3 cp s3://$BBBStackBucketStack/turn-handler.timer /etc/systemd/system/turn-handler.timer
aws s3 cp s3://$BBBStackBucketStack/turn-handler.sh /usr/local/bin/turn-handler.sh
chmod +x /usr/local/bin/turn-handler.sh

sed -i "s/AWSREGION_PLACEHOLDER/$AWSRegion/g" /etc/systemd/system/turn-handler.service
sed -i "s|PARAMETER_PLACEHOLDER|$BBBTurnHostnameParameter|g" /etc/systemd/system/turn-handler.service

systemctl daemon-reload
systemctl enable turn-handler.timer
systemctl start turn-handler.timer