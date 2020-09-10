#!/bin/bash
# script handler route53 entries on startup / shutdown
# created by suredavi@amazon.de
# only for testing

while getopts ":h:m:z:" opt; do
  case $opt in
    h) HOSTNAME="$OPTARG"
    ;;
    m) METHOD="$OPTARG"
    ;;
    z) ZONE="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done

if [[ $METHOD == "create" ]]; then
  instance_ipv4=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
  /usr/local/bin/cli53 rrcreate --replace $ZONE "$HOSTNAME 60 A $instance_ipv4"
fi

if [[ $METHOD == "delete" ]]; then
  /usr/local/bin/cli53 rrdelete $ZONE $HOSTNAME A
fi

exit 0