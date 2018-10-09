#!/bin/sh
OS='ubuntu-16.04'

# TEST 1
#  const: total - 12,000
#         batch - 3,000
#         backend - sqlite (default)
#         WB - yes (default)
#         PP_Log - no
#         all_log - no
#         heart - 2000K (default)
#         timeout - 10,000K to 18,000K (default)
#  var:   type (insert orders, account transfer, create accout, account transfer unique)

echo 'TEST 1 ------------  '
DIRNAME='test1-type'
TOTAL='12000'
BATCH='3000'
rm -rf $DIRNAME
mkdir $DIRNAME
cd kadena-beta/ &&
yes '' | ./bin/$OS/genconfs --distributed aws/ipAddr.yml &&
cd ../ &&
ansible-playbook kadena-beta/aws/edit_conf.yml --tags "no_pactPersist_log, no_debug"

echo 'TEST 1 - TYPE - Account Transfer'
TYPE='--at'
FILENAME='account_transfer.log'
ansible-playbook kadena-beta/aws/run_servers.yml &&
rlwrap -A ./kadena-beta/bin/$OS/inserts $TYPE -t$TOTAL -b$BATCH --norunserver --configfile=client.yaml --dirforconfig=kadena-beta/conf/ 2>&1 | tee -a $DIRNAME/$FILENAME

echo 'TEST 1 - TYPE - Create Account'
TYPE='--ca'
FILENAME='create_account.log'
ansible-playbook kadena-beta/aws/run_servers.yml &&
rlwrap -A ./kadena-beta/bin/$OS/inserts $TYPE -t$TOTAL -b$BATCH --norunserver --configfile=client.yaml --dirforconfig=kadena-beta/conf/ 2>&1 | tee -a $DIRNAME/$FILENAME

echo 'TEST 1 - TYPE - Account Transfer Unique'
TYPE='--atu'
FILENAME='account_transfer_unique.log'
ansible-playbook kadena-beta/aws/run_servers.yml &&
rlwrap -A ./kadena-beta/bin/$OS/inserts $TYPE -t$TOTAL -b$BATCH --norunserver --configfile=client.yaml --dirforconfig=kadena-beta/conf/ 2>&1 | tee -a $DIRNAME/$FILENAME

echo 'TEST 1 - TYPE - Insert Orders'
TYPE='--io'
FILENAME='insert_orders.log'
ansible-playbook kadena-beta/aws/run_servers.yml &&
rlwrap -A ./kadena-beta/bin/$OS/inserts $TYPE -t$TOTAL -b$BATCH --norunserver --configfile=client.yaml --dirforconfig=kadena-beta/conf/ 2>&1 | tee -a $DIRNAME/$FILENAME

echo 'TEST 1 - CREATING SUMMARY'
touch $DIRNAME/summary.log

echo '------ ACCOUNT TRANSFER ------- ' >> $DIRNAME/summary.log
tail -n 14 $DIRNAME/account_transfer.log >> $DIRNAME/summary.log
echo '------ CREATE ACCOUNT ------- ' >> $DIRNAME/summary.log
tail -n 14 $DIRNAME/create_account.log >> $DIRNAME/summary.log
echo '------ ACCOUNT TRANSFER UNIQUE ------- ' >> $DIRNAME/summary.log
tail -n 14 $DIRNAME/account_transfer_unique.log >> $DIRNAME/summary.log
echo '------ INSERT ORDERS ------- ' >> $DIRNAME/summary.log
tail -n 14 $DIRNAME/insert_orders.log >> $DIRNAME/summary.log
