#!/bin/sh

OS='ubuntu-16.04'

rm ./log/*
touch ./log/node0.log ./log/node1.log ./log/node2.log ./log/node3.log 
tmux new-window
tmux split-window -h
tmux send-keys './bin/'$OS'/kadenaserver +RTS -N4 -RTS -c conf/10000-cluster.yaml &' C-m
tmux send-keys 'tail -f ./log/node0.log' C-m
sleep 1
tmux split-window -v -p 75
tmux send-keys './bin/'$OS'/kadenaserver +RTS -N4 -RTS -c conf/10001-cluster.yaml &' C-m
tmux send-keys 'tail -f ./log/node1.log' C-m
sleep 1
tmux split-window -v -p 66
tmux send-keys './bin/'$OS'/kadenaserver +RTS -N4 -RTS -c conf/10002-cluster.yaml &' C-m
tmux send-keys 'tail -f ./log/node2.log' C-m
sleep 1
tmux split-window -v -p 50
tmux send-keys './bin/'$OS'/kadenaserver +RTS -N4 -RTS -c conf/10003-cluster.yaml &' C-m
tmux send-keys 'tail -f ./log/node3.log' C-m
sleep 1
tmux select-pane -L
tmux send-keys './kadenaclient.sh'
