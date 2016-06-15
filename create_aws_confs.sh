#!/bin/bash

rm aws-conf/*yaml aws-conf/*privateIp

aws ec2 describe-instances --filter Name=tag:Name,Values=junoserver \
  | grep '"PrivateIpAddress"' \
  | sed 's/[^(0-9).]//g' \
  | uniq | sort > aws-conf/junoservers.privateIp

aws ec2 describe-instances --filter Name=tag:Name,Values=junoclient \
  | grep '"PrivateIpAddress"' \
  | sed 's/[^(0-9).]//g' \
  | uniq | sort > aws-conf/junoclient.privateIp

stack exec -- genconfs --aws aws-conf/junoservers.privateIp aws-conf/junoclient.privateIp
