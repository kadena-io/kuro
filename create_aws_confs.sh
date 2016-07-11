#!/bin/bash

if [ -d "aws-conf" ]
then
    rm -rf aws-conf/*
else
    mkdir aws-conf
fi

aws ec2 describe-instances --filter Name=tag:Name,Values=junoserver \
  | grep '"PrivateIpAddress"' \
  | sed 's/[^(0-9).]//g' \
  | uniq | sort > aws-conf/junoservers.privateIp

aws ec2 describe-instances --filter Name=tag:Name,Values=junoclient \
  | grep '"PrivateIpAddress"' \
  | sed 's/[^(0-9).]//g' \
  | uniq | sort > aws-conf/junoclient.privateIp

stack exec -- genconfs --aws aws-conf/junoservers.privateIp aws-conf/junoclient.privateIp

for ip in `cat aws-conf/junoservers.privateIp`; do
    idir="aws-conf/${ip}"
    mkdir -p $idir/conf
    conf="${ip}-cluster-aws.yaml"
    script="${idir}/start.sh"
    mv aws-conf/$conf $idir/conf/$conf
    echo "#!/bin/sh
nohup ./junoserver +RTS -N8 -T -RTS -c conf/${conf} --apiPort 8000 --disablePersistence > /dev/null 2>&1 &
" > $script
    chmod +x $script
done
