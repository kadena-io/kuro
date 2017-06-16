#!/bin/sh

if [ ! -d "aws-conf" ];then echo "Can't find kadena/aws-conf"; exit 1; fi
cd aws-conf

cmd="$1"
case $cmd in
  distBins)
      for i in `cat kadenaservers.privateIp`; do
          scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/user.pem -r ../bin/kadenaserver ec2-user@$i: &
      done
      for i in `cat kadenaservers.privateIp`; do
          ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/user.pem ec2-user@$i 'mkdir ./conf; mkdir ./log' &
      done
    exit 0
    ;;
  config)
    for i in `cat kadenaservers.privateIp`;
      do scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/user.pem -r $i/* ec2-user@$i: & done
    exit 0
    ;;
  start)
    for i in `cat kadenaservers.privateIp`;
      do ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/user.pem ec2-user@$i './start.sh' & done
    exit 0
    ;;
  stop)
    for i in `cat kadenaservers.privateIp`;
      do ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/user.pem ec2-user@$i 'pkill kadenaserver' & done
    exit 0
    ;;
  map)
      for i in `cat kadenaservers.privateIp`;
      do ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/user.pem ec2-user@$i "${@:2}" ; done
         exit 0
         ;;
  status)
    for i in `cat kadenaservers.privateIp`;
      do echo $i ; curl -sH "Accept: application/json" "$i:10080" | jq '.kadena | {role: .node.role.val, commit_index: .consensus.commit_index.val, applied_index: .node.applied_index.val}' ; done
    exit 0
    ;;
  copyLogs)
    for i in `cat kadenaservers.privateIp`; do scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/user.pem -r ec2-user@$i:./${i}-output.log ~/kadena/cluster-logs/${i}-output.log & done
    exit 0
    ;;
  reset)
    for i in `cat kadenaservers.privateIp`; do ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/user.pem ec2-user@$i 'rm ~/*-output.log ~/log/*' & done
    exit 0
    ;;
  ps)
    for i in `cat kadenaservers.privateIp`; do ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/user.pem ec2-user@$i 'pgrep kadenaserver' & done
    exit 0
    ;;
  *)
    echo "Commands: distBins config start stop copyLogs clearLogs ps map"
    ;;
esac
