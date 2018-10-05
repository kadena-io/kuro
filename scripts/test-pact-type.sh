#!/bin/sh
OS='ubuntu-16.04'

# TEST 1
#  const: total - 12,000
#         batch - 3,000
#         backend - sqlite (default)
#         WB - yes (default)
#         PP_Log - yes (default)
#         all_log - yes (default)
#         heart - 2000K (default)
#         timeout - 10,000K to 18,000K (default)
#  var:   type (insert orders, account transfer, create accout, account transfer unique)

echo 'TEST 1 ------------  '
  DIRNAME='test1-type'
  TOTAL='12000'
  BATCH='3000'
  rm -rf ~/$DIRNAME
  mkdir ~/$DIRNAME
  touch ~/$DIRNAME/summary.log
  yes '' | ./bin/$OS/genconfs --distributed aws/ipAddr.yml &&

echo 'TEST 1 - TYPE - Account Transfer'
  TYPE='--at'
  TESTNAME='account_transfer'
  mkdir ~/$DIRNAME/$TESTNAME
  ansible-playbook aws/run_servers.yml &&
  rlwrap -A ./bin/$OS/inserts $TYPE -t$TOTAL -b$BATCH --norunserver -c=client.yaml -d=conf/ 2>&1 | tee -a ~/$DIRNAME/$TESTNAME/$TESTNAME.log &&
  ansible-playbook aws/get_server_logs.yml &&
  mv aws/logs/* ~/$DIRNAME/$TESTNAME &&
  echo "---- $TESTNAME ----" >> ~/$DIRNAME/summary.log
  tail -n 14 ~/$DIRNAME/$TESTNAME/$TESTNAME.log >> ~/$DIRNAME/summary.log

echo 'TEST 1 - TYPE - Create Account'
  TYPE='--ca'
  TESTNAME='create_account'
  mkdir ~/$DIRNAME/$TESTNAME
  ansible-playbook aws/run_servers.yml &&
  rlwrap -A ./bin/$OS/inserts $TYPE -t$TOTAL -b$BATCH --norunserver -c=client.yaml -d=conf/ 2>&1 | tee -a ~/$DIRNAME/$TESTNAME/$TESTNAME.log &&
  ansible-playbook aws/get_server_logs.yml &&
  mv aws/logs/* ~/$DIRNAME/$TESTNAME &&
  echo "---- $TESTNAME ----" >> ~/$DIRNAME/summary.log
  tail -n 14 ~/$DIRNAME/$TESTNAME/$TESTNAME.log >> ~/$DIRNAME/summary.log

echo 'TEST 1 - TYPE - Account Transfer Unique'
  TYPE='--atu'
  TESTNAME='account_transfer_unique'
  mkdir ~/$DIRNAME/$TESTNAME
  ansible-playbook aws/run_servers.yml &&
  rlwrap -A ./bin/$OS/inserts $TYPE -t$TOTAL -b$BATCH --norunserver -c=client.yaml -d=conf/ 2>&1 | tee -a ~/$DIRNAME/$TESTNAME/$TESTNAME.log &&
  ansible-playbook aws/get_server_logs.yml &&
  mv aws/logs/* ~/$DIRNAME/$TESTNAME &&
  echo "---- $TESTNAME ----" >> ~/$DIRNAME/summary.log
  tail -n 14 ~/$DIRNAME/$TESTNAME/$TESTNAME.log >> ~/$DIRNAME/summary.log

echo 'TEST 1 - TYPE - Insert Orders'
  TYPE='--io'
  TESTNAME='insert_orders'
  mkdir ~/$DIRNAME/$TESTNAME
  ansible-playbook aws/run_servers.yml &&
  rlwrap -A ./bin/$OS/inserts $TYPE -t$TOTAL -b$BATCH --norunserver -c=client.yaml -d=conf/ 2>&1 | tee -a ~/$DIRNAME/$TESTNAME/$TESTNAME.log &&
  ansible-playbook aws/get_server_logs.yml &&
  mv aws/logs/* ~/$DIRNAME/$TESTNAME &&
  echo "---- $TESTNAME ----" >> ~/$DIRNAME/summary.log
  tail -n 14 ~/$DIRNAME/$TESTNAME/$TESTNAME.log >> ~/$DIRNAME/summary.log
