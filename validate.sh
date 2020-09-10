#!/bin/bash
# This is a simple bash script for the BBB Application Infrastructure.
# It simply validates the Amazon Cloudformation templates.

# created by David Surey - suredavi@amazon.de
# Disclaimber: NOT FOR PRODUCTION USE - Only for demo and testing purposes
ERROR_COUNT=0; 

if [[ $# -lt 1 ]] ; then
    echo 'arguments missing, please provide a aws profile string (-p)'
    exit 1
fi

while getopts ":p:e:s" opt; do
  case $opt in
    p) BBBPROFILE="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done

echo "using AWS Profile $BBBPROFILE"
echo "##################################################"

echo "Validating AWS CloudFormation templates..."
echo "##################################################"
# Loop through the YAML templates in this repository
for TEMPLATE in $(find . -name 'bbb-on-aws-*.template.yaml'); do 

    # Validate the template with CloudFormation
    ERRORS=$(aws cloudformation validate-template --profile=$BBBPROFILE --template-body file://$TEMPLATE 2>&1 >/dev/null); 
    if [ "$?" -gt "1" ]; then 
        ((ERROR_COUNT++));
        echo "[fail] $TEMPLATE: $ERRORS";
    else 
        echo "[pass] $TEMPLATE";
    fi; 
    
done; 

# Error out if templates are not validate. 
echo "$ERROR_COUNT template validation error(s)"; 
if [ "$ERROR_COUNT" -gt 1 ]; 
    then exit 1; 
fi

echo "##################################################"
echo "Validating of AWS CloudFormation templates finished"
echo "##################################################"

exit 0 