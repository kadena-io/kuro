#!/bin/bash

OS='ubuntu-16.04'

sudo chmod +x /home/ubuntu/kadena-beta/bin/$OS/kadenaclient
ansible-playbook /home/ubuntu/kadena/scripts/aws/run_servers.yml &&
rlwrap -A /home/ubuntu/kadena-beta/bin/$OS/kadenaclient -c "/home/ubuntu/conf/$(ls conf | grep -m 1 client)" +RTS -N2
