#!/bin/bash
# Script handles the add and remove for Application Server instances into scalelite
# only for testing purposes

while getopts ":s:p:m:r:c:" opt; do
  case $opt in
    p) SECRET="$OPTARG"
    ;;
    s) SERVER="$OPTARG"
    ;;
    m) METHOD="$OPTARG"
    ;;
    r) REGION="$OPTARG"
    ;;
    c) ECS_CLUSTER="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done

OIFS=$IFS;
IFS=",";

# get the Scalelite Information
SCALELITE_SERVICE=$(aws ecs list-services --region $REGION --cluster $ECS_CLUSTER --query "serviceArns[?contains(@, 'BBBScaleliteService')]" --output text | xargs -n 1 basename)
SCALELITE_TASK=$(aws ecs list-tasks --region $REGION --cluster $ECS_CLUSTER --service $SCALELITE_SERVICE --output text | awk -F"/" '{print $NF}' | rev | awk -F"/" '{print $1}' | rev)

# Decide if to add or to remove
if [[ $METHOD == "create" ]]; then
  COMMAND_STRING="id=\$(bin/rake servers:add[$SERVER,$SECRET] | tail -n 1 | sed 's/id: //g'); bin/rake servers:enable[\$id];"
fi

if [[ $METHOD == "delete" ]]; then
  COMMAND_STRING="id=\$(bin/rake servers | grep -B 1 "$SERVER" | head -n 1 | sed 's/id: //g'); bin/rake servers:panic[\$id] && bin/rake servers:remove[\$id]"
fi

# execute the needed command at the api container
aws ecs execute-command --region $REGION --cluster "$ECS_CLUSTER" --task $SCALELITE_TASK --container scalelite-api --interactive --command "/bin/sh -c \"$COMMAND_STRING\""

IFS=$OIFS;