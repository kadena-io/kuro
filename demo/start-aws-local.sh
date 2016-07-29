#!/bin/sh
rm ./log/*.sqlite
tmux new-window
tmux split-window -h
tmux send-keys '~/junoserver +RTS -N4 -T -RTS -c conf/10000-cluster.yaml --apiPort 8000 --disablePersistence' C-m
sleep 1
tmux split-window -v -p 75
tmux send-keys '~/junoserver +RTS -N4 -T -RTS -c conf/10001-cluster.yaml --apiPort 8001 --disablePersistence' C-m
sleep 1
tmux split-window -v -p 66
tmux send-keys '~/junoserver +RTS -N4 -T -RTS -c conf/10002-cluster.yaml --apiPort 8002 --disablePersistence' C-m
sleep 1
tmux split-window -v -p 50
tmux send-keys '~/junoserver +RTS -N4 -T -RTS -c conf/10003-cluster.yaml --apiPort 8003 --disablePersistence' C-m
sleep 1
tmux select-pane -L
tmux send-keys '~/junoclient -c "conf/$(ls conf | grep -m 1 client)" +RTS -N2'
