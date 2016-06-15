#!/bin/bash

aws ec2 describe-instances --filter Name=tag:Name,Values=junoserver \
  | grep '"PrivateIpAddress"' \
  | sed 's/[^(0-9).]//g' \
  | uniq | sort > junoservers.privateIp

aws ec2 describe-instances --filter Name=tag:Name,Values=junoclient \
  | grep '"PrivateIpAddress"' \
  | sed 's/[^(0-9).]//g' \
  | uniq | sort > junoclient.privateIp

stack exec -- genconfs --aws
