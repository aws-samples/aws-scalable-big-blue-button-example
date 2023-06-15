#!/bin/bash
# This is a simple bash script for the BBB Application Infrastructure deployment. 
# It basically glues together the parts running in loose coupeling during the deployment and helps to speed things up which
# otherwise would have to be noted down and put into the command line. 
# This can be migrated into real orchestration / automation toolsets if needed (e.g. Ansible, Puppet or Terraform)

# created by David Surey - suredavi@amazon.de
# Disclaimber: NOT FOR PRODUCTION USE - Only for demo and testing purposes

ERROR_COUNT=0; 

if [[ $# -lt 2 ]] ; then
    echo 'arguments missing, please the aws profile string (-p) and the deployment Stack Name (-s)'
    exit 1
fi

while getopts ":p:s:" opt; do
  case $opt in
    p) BBBPROFILE="$OPTARG"
    ;;
    s) BBBSTACK="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done

if ! [ -x "$(command -v aws)" ]; then
  echo 'Error: aws cli is not installed.' >&2
  exit 1
fi

echo "using AWS Profile $BBBPROFILE"
echo "##################################################"

# Empty the ECR Repository
ENVIRONMENTTYPE=$(jq -r ".Parameters.BBBEnvironmentType" bbb-on-aws-param.json)
if [ "$ENVIRONMENTTYPE" == 'scalable' ]
then 
  echo "Deleting all (cached) images from ECR repository"
  echo "##################################################"
  GREENLIGHTREGISTRY=$(aws ecr describe-repositories --profile=$BBBPROFILE --query 'repositories[?contains(repositoryName, `greenlight`)].repositoryName' --output text)
  SCALELITEREGISTRY=$(aws ecr describe-repositories --profile=$BBBPROFILE --query 'repositories[?contains(repositoryName, `scalelite`)].repositoryName' --output text)
  IMAGESGREENLIGHT=$(aws --profile $BBBPROFILE ecr describe-images --repository-name $GREENLIGHTREGISTRY --output json | jq '.[]' | jq '.[]' | jq "select (.imagePushedAt > 0)" | jq -r '.imageDigest')
  for IMAGE in ${IMAGESGREENLIGHT[*]}; do
      echo "Deleting $IMAGE"
      aws ecr --profile $BBBPROFILE batch-delete-image --repository-name $GREENLIGHTREGISTRY --image-ids imageDigest=$IMAGE
  done
  IMAGESSCALELITE=$(aws --profile $BBBPROFILE ecr describe-images --repository-name $SCALELITEREGISTRY --output json | jq '.[]' | jq '.[]' | jq "select (.imagePushedAt > 0)" | jq -r '.imageDigest')
  for IMAGE in ${IMAGESSCALELITE[*]}; do
      echo "Deleting $IMAGE"
      aws ecr --profile $BBBPROFILE batch-delete-image --repository-name $SCALELITEREGISTRY --image-ids imageDigest=$IMAGE
  done  
fi

# Destroy the BBB infrastructure. 
echo "Delete the BBB Environment"
echo "##################################################"
aws cloudformation delete-stack --profile=$BBBPROFILE --stack-name $BBBSTACK 

aws cloudformation wait stack-delete-complete --profile=$BBBPROFILE --stack-name $BBBSTACK

echo "##################################################"
echo "Deletion finished"

# Destroy Bucket and ECR 
echo "deleting the Prerequisites stacks"
echo "##################################################"

BBBPREPSTACK="${BBBSTACK}-Sources"
SOURCE=`aws cloudformation describe-stacks --profile=$BBBPROFILE --query "Stacks[0].Outputs[0].OutputValue" --stack-name $BBBPREPSTACK`

SOURCE=`echo "${SOURCE//\"}"`

echo "##################################################"
echo "Truncate the S3 Bucket"
echo "##################################################"
#aws s3 rm --profile=$BBBPROFILE s3://$SOURCE --recursive

aws s3api --profile=$BBBPROFILE list-object-versions \
          --bucket $SOURCE \
          --query "Versions[].Key"  \
          --output json | jq 'unique' | jq -r '.[]' | while read key; do
   echo "deleting versions of $key"
   aws s3api --profile=$BBBPROFILE list-object-versions \
          --bucket $SOURCE \
          --prefix $key \
          --query "Versions[].VersionId"  \
          --output json | jq 'unique' | jq -r '.[]' | while read version; do
     echo "deleting $version"
     aws s3api --profile=$BBBPROFILE delete-object \
          --bucket $SOURCE \
          --key $key \
          --version-id $version 
   done
done          

aws cloudformation delete-stack --stack-name $BBBPREPSTACK --profile=$BBBPROFILE
aws cloudformation wait stack-delete-complete --profile=$BBBPROFILE --stack-name $BBBPREPSTACK

echo "##################################################"
echo "Deletion done"


exit 0 
