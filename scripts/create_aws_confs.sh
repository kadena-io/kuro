#!/bin/bash

if [ -d "aws-conf" ]
then
    rm -rf aws-conf/*
else
    mkdir aws-conf
fi

aws ec2 describe-instances --filter Name=tag:Name,Values=kadenaserver \
  | grep '"PrivateIpAddress"' \
  | sed 's/[^(0-9).]//g' \
  | uniq | sort > aws-conf/kadenaservers.privateIp

aws ec2 describe-instances --filter Name=tag:Name,Values=kadenaclient \
  | grep '"PrivateIpAddress"' \
  | sed 's/[^(0-9).]//g' \
  | uniq | sort > aws-conf/kadenaclient.privateIp

./bin/genconfs --distributed aws-conf/kadenaservers.privateIp

for ip in `cat aws-conf/kadenaservers.privateIp`; do
    idir="aws-conf/${ip}"
    mkdir -p $idir/conf
    conf="${ip}-cluster.yaml"
    script="${idir}/start.sh"
    mv ./conf/$conf $idir/conf/$conf
    echo "#!/bin/sh
nohup ./kadenaserver +RTS -N -RTS -c conf/${conf} >> ./${ip}-output.log 2>&1 &
" > $script
    chmod +x $script
done

echo 'make sure you have run `stack install` from kadena and have `~/.local/bin` in your path (or have run `cd ~ ; ln -s .local/bin/* . `)'
