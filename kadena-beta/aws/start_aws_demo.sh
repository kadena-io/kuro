#!/bin/bash

OS='ubuntu-16.04'
EC2_USER='ubuntu'

sudo chmod +x bin/$OS/kadenaclient
ansible-playbook aws/run_servers.yml &&

tmux new-window &&

tmux split-window -h &&
tmux send-keys "ssh -t -A $EC2_USER@${SERVERS[0]} tail -f log/node.log" C-m &&

tmux split-window -v -p 75 &&
tmux send-keys "ssh -t -A $EC2_USER@${SERVERS[1]} tail -f log/node.log" C-m &&

tmux split-window -v -p 66 &&
tmux send-keys "ssh -t -A $EC2_USER@${SERVERS[2]} tail -f log/node.log" C-m &&

tmux split-window -v -p 50 &&
tmux send-keys "ssh -t -A $EC2_USER@${SERVERS[3]} tail -f log/node.log" C-m &&

tmux select-pane -L &&
tmux send-keys "rlwrap -A bin/$OS/kadenaclient -c conf/client.yaml +RTS -N2"
