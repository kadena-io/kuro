#!/bin/sh
rm ./log/*.sqlite* ./log/10000.log ./log/10001.log ./log/10002.log ./log/10003.log ./log/access.log ./log/error.log ./log/client.log
touch ./log/access.log ./log/error.log
tmux new-window
tmux split-window -h
tmux send-keys './bin/kadenaserver +RTS -N4 -RTS -c conf/10000-cluster.yaml 2>&1 | tee -a log/10000.log ' C-m
sleep 1
tmux split-window -v -p 75
tmux send-keys './bin/kadenaserver +RTS -N4 -RTS -c conf/10001-cluster.yaml 2>&1 | tee -a log/10001.log ' C-m
sleep 1
tmux split-window -v -p 66
tmux send-keys './bin/kadenaserver +RTS -N4 -RTS -c conf/10002-cluster.yaml 2>&1 | tee -a log/10002.log ' C-m
sleep 1
tmux split-window -v -p 50
tmux send-keys './bin/kadenaserver +RTS -N4 -RTS -c conf/10003-cluster.yaml 2>&1 | tee -a log/10003.log ' C-m
sleep 1
tmux select-pane -L
tmux send-keys './kadenaclient.sh'
