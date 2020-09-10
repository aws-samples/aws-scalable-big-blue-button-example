#!/bin/bash
# script to watch turn server hostname changes and adjust config
# created by suredavi@amazon.de
# only for testing

while getopts ":r:p:" opt; do
  case $opt in
    r) REGION="$OPTARG"
    ;;
    p) PARAMETER="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done

turn_hostname=$(aws ssm get-parameter --region $REGION --name $PARAMETER --with-decryption --output text --query Parameter.Value)

turn_uptodate=$(grep "$turn_hostname" -q /usr/share/bbb-web/WEB-INF/classes/spring/turn-stun-servers.xml && echo "UPTODATE" || echo "TOBEUPDATED")

if [[ $turn_uptodate == "TOBEUPDATED" ]]; then
  sed -i "s/tu-[^\.]*/$turn_hostname/g" /usr/share/bbb-web/WEB-INF/classes/spring/turn-stun-servers.xml
  usr/bin/bbb-conf --restart
fi

exit 0