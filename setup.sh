#!/bin/bash
# This is a simple bash script for the BBB Application Infrastructure deployment. 
# It basically glues together the parts running in loose coupeling during the deployment and helps to speed things up which
# otherwise would have to be noted down and put into the command line. 
# This can be migrated into real orchestration / automation toolsets if needed (e.g. Ansible, Puppet or Terraform)

# created by David Surey - suredavi@amazon.de
# Disclaimber: NOT FOR PRODUCTION USE - Only for demo and testing purposes

ERROR_COUNT=0; 

if [[ $# -lt 5 ]] ; then
    echo 'arguments missing, please provide at least email (-e), the aws profile string (-p), the domain name (-d), the deployment Stack Name (-s) and the hosted zone to be used (-h)'
    exit 1
fi

while getopts ":p:e:h:s:d:" opt; do
  case $opt in
    p) BBBPROFILE="$OPTARG"
    ;;
    e) OPERATOREMAIL="$OPTARG"
    ;;
    h) HOSTEDZONE="$OPTARG"
    ;;
    s) BBBSTACK="$OPTARG"
    ;;
    d) DOMAIN="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done

if ! [ -x "$(command -v aws)" ]; then
  echo 'ERROR: aws cli is not installed.' >&2
  exit 1
fi

if ! docker ps -q 2>/dev/null; then
 echo "ERROR: Docker is not running. Please start the docker runtime on your system and try again"
 exit 1
fi

echo "using AWS Profile $BBBPROFILE"
echo "##################################################"

echo "Validating AWS CloudFormation templates..."
echo "##################################################"
# Loop through the YAML templates in this repository
for TEMPLATE in $(find . -name 'bbb-on-aws-*.template.yaml'); do 

    # Validate the template with CloudFormation
    ERRORS=$(aws cloudformation validate-template --profile=$BBBPROFILE --template-body file://$TEMPLATE 2>&1 >/dev/null); 
    if [ "$?" -gt "0" ]; then 
        ((ERROR_COUNT++));
        echo "[fail] $TEMPLATE: $ERRORS";
    else 
        echo "[pass] $TEMPLATE";
    fi; 
    
done; 

# Error out if templates are not validate. 
echo "$ERROR_COUNT template validation error(s)"; 
if [ "$ERROR_COUNT" -gt 0 ]; 
    then exit 1; 
fi

echo "##################################################"
echo "Validating of AWS CloudFormation templates finished"
echo "##################################################"

# Deploy the Needed Buckets for the later build 
echo "deploy the Prerequisites of the BBB Environment and Application if needed"
echo "##################################################"
BBBPREPSTACK="${BBBSTACK}-Sources"
aws cloudformation deploy --stack-name $BBBPREPSTACK --profile=$BBBPROFILE --template ./templates/bbb-on-aws-buildbuckets.template.yaml
echo "##################################################"
echo "deployment done"

SOURCE=$(aws cloudformation describe-stack-resources --profile $BBBPROFILE --stack-name $BBBPREPSTACK --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" --output text)

# we will upload the needed CFN Templates to S3 containing the IaaC Code which deploys the actual infrastructure.
# This will error out if the source files are missing. 
echo "##################################################"
echo "Copy Files to the S3 Bucket for further usage"
echo "##################################################"
if [ -e . ]
then
    echo "##################################################"
    echo "copy BBB code source file"
    aws s3 sync --profile=$BBBPROFILE --exclude=".DS_Store" ./templates s3://$SOURCE
    aws s3 sync --profile=$BBBPROFILE --exclude=".DS_Store" ./scripts s3://$SOURCE
    echo "##################################################"
else
    echo "BBB code source file missing"
    echo "##################################################"
    exit 1
fi
echo "##################################################"
echo "File Copy finished"

ENVIRONMENTTYPE=$(jq -r ".Parameters.BBBEnvironmentType" bbb-on-aws-param.json)

if [ "$ENVIRONMENTTYPE" == 'scalable' ]
then 
  BBBECRStack="${BBBSTACK}-registry"
  aws cloudformation deploy --profile=$BBBPROFILE --stack-name $BBBECRStack  \
      --parameter-overrides $PARAMETERS \
      $(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' bbb-on-aws-param.json) \
      --template ./templates/bbb-on-aws-registry.template.yaml

  GREENLIGHTIMAGE=$(aws ecr describe-repositories --profile=$BBBPROFILE --query 'repositories[?contains(repositoryName, `greenlight`)].repositoryName' --output text)
  SCALELITEIMAGE=$(aws ecr describe-repositories --profile=$BBBPROFILE --query 'repositories[?contains(repositoryName, `scalelite`)].repositoryName' --output text)

  SCALELITEREGISTRY=$(aws ecr describe-repositories --profile=$BBBPROFILE --query 'repositories[?contains(repositoryName, `scalelite`)].repositoryUri' --output text)
  GREENLIGHTREGISTRY=$(aws ecr describe-repositories --profile=$BBBPROFILE --query 'repositories[?contains(repositoryName, `greenlight`)].repositoryUri' --output text)

  # we will mirror the needed images from dockerhub and push towards ECR
  echo "##################################################"
  echo "Mirror docker images to ECR for further usage"
  echo "##################################################"
  
  SCALELITEIMAGETAGS=( BBBScaleliteNginxImageTag BBBScaleliteApiImageTag BBBScalelitePollerImageTag BBBScaleliteImporterImageTag )
  GREENLIGHTIMAGETAGS=( BBBgreenlightImageTag )

  aws ecr get-login-password --profile=$BBBPROFILE | docker login --username AWS --password-stdin $SCALEILITEREGISTRY
  aws ecr get-login-password --profile=$BBBPROFILE | docker login --username AWS --password-stdin $GREENLIGHTREGISTRY

  for IMAGETAG in "${SCALELITEIMAGETAGS[@]}"
  do
    IMAGETAG=$(jq -r ".Parameters.$IMAGETAG" bbb-on-aws-param.json)
    docker pull $SCALELITEIMAGE:$IMAGETAG
    docker tag $SCALELITEIMAGE:$IMAGETAG $SCALELITEREGISTRY:$IMAGETAG
    docker push $SCALELITEREGISTRY:$IMAGETAG
  done
  for IMAGETAG in "${GREENLIGHTIMAGETAGS[@]}"
  do
    IMAGETAG=$(jq -r ".Parameters.$IMAGETAG" bbb-on-aws-param.json)
    docker pull $GREENLIGHTIMAGE:$IMAGETAG
    docker tag $GREENLIGHTIMAGE:$IMAGETAG $GREENLIGHTREGISTRY:$IMAGETAG
    docker push $GREENLIGHTREGISTRY:$IMAGETAG
  done

  echo "##################################################"
  echo "Registry Preperation finished"
fi

# Setting the dynamic Parameters for the Deployment
PARAMETERS=" BBBOperatorEMail=$OPERATOREMAIL \
             BBBStackBucketStack=$BBBSTACK-Sources \
             BBBDomainName=$DOMAIN \
             BBBHostedZone=$HOSTEDZONE \
             BBBECRStack=$BBBSTACK-Registry"

# Deploy the BBB infrastructure. 
echo "Building the BBB Environment"
echo "##################################################"
aws cloudformation deploy --profile=$BBBPROFILE --stack-name $BBBSTACK \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides $PARAMETERS \
    $(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' bbb-on-aws-param.json) \
    --template ./bbb-on-aws-root.template.yaml

# Set the initial admin password for the environment
echo "Setting the intial admin password"
echo "##################################################"

#get the secrets
ADMIN_SECRET=$(aws secretsmanager list-secrets --profile $BBBPROFILE --filter Key="name",Values="BBBAdministratorlogin" --query 'SecretList[0].Name' --output text)
ADMIN_AUTH=$(aws secretsmanager get-secret-value --profile $BBBPROFILE --secret-id $ADMIN_SECRET)
ADMIN_PASSWORD=$(echo "$ADMIN_AUTH" | jq -r '.SecretString | fromjson | .password')
ADMIN_LOGIN=$(echo "$ADMIN_AUTH" | jq -r '.SecretString | fromjson | .username')

#get the cluster information
ECS_CLUSTERS=$(aws ecs --profile=$BBBPROFILE list-clusters)
ECS_CLUSTER=$(echo "$ECS_CLUSTERS" | jq -r '.clusterArns[0] | split("/") | .[1]')

# get my greenlight service
GREENLIGHT_SERVICE=$(aws ecs list-services --profile $BBBPROFILE --cluster $ECS_CLUSTER --query "serviceArns[?contains(@, 'BBBgreenlightService')]" --output text | xargs -n 1 basename)
GREENLIGHT_TASK=$(aws ecs list-tasks --profile $BBBPROFILE --cluster $ECS_CLUSTER --service $GREENLIGHT_SERVICE --output text | awk -F"/" '{print $NF}' | rev | awk -F"/" '{print $1}' | rev)

aws ecs execute-command --profile=$BBBPROFILE --cluster $ECS_CLUSTER \
    --task $GREENLIGHT_TASK \
    --container greenlight \
    --interactive \
    --command "bundle exec rake admin:create["bbbadmin","${ADMIN_LOGIN}","${ADMIN_PASSWORD}"]"

echo "##################################################"
echo "Deployment finished"

exit 0