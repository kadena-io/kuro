#!/bin/bash

OS='ubuntu-16.04'

sudo chmod +x /home/ubuntu/kadena-beta/bin/$OS/kadenaclient
ansible-playbook /home/ubuntu/kadena/scripts/aws/run_servers.yml &&
STR_SERVERS=`cat /home/ubuntu/ipAddr.yml`
SERVERS=( $STR_SERVERS )
if [ ${#SERVERS[*]} -ne 4 ]
then
  echo "Received ${#SERVERS[@]} kadenaservers but expected 4"
  exit 1
fi

tmux new-window

tmux split-window -h
tmux send-keys "ssh -t -A ubuntu@${SERVERS[0]} tail -f log/node.log" C-m

tmux split-window -v -p 75
tmux send-keys "ssh -t -A ubuntu@${SERVERS[1]} tail -f log/node.log" C-m

tmux split-window -v -p 66
tmux send-keys "ssh -t -A ubuntu@${SERVERS[2]} tail -f log/node.log" C-m

tmux split-window -v -p 50
tmux send-keys "ssh -t -A ubuntu@${SERVERS[3]} tail -f log/node.log" C-m

tmux select-pane -L
tmux send-keys "rlwrap -A /home/ubuntu/kadena-beta/bin/$OS/kadenaclient -c /home/ubuntu/conf/client.yaml +RTS -N2"
