# Servers
* ssh root@54.226.139.117       -- "Build" machine

* ssh root@54.166.153.21        -- Node 0

* ssh root@54.146.43.204        -- Node 1

* ssh root@34.204.71.247        -- Node 2

* ssh root@54.164.36.85         -- Node 3

# Server directories
* bin: /var/lib/kadena/profiles/current/bin/kadenaserver

* working dir: /var/lib/kadena/run

* conf files: /root/kadena/10000-cluster.yaml, etc

* log files: /var/lib/kadena/run/log

# ssh to each server and create directories:
* mkdir /var/lib/kadena

* mkdir /var/lib/kadena/profiles

* mkdir /var/lib/kadena/run

* mkdir /var/lib/kadena/run/log

* mkdir /root/kadena

# SCP config to each node (from kadena dir locally)
###    node0:
* scp nix/conf/* root@54.166.153.21:/root/kadena/

###   node1:
* scp nix/conf/* root@54.146.43.204:/root/kadena/

###    node2:
* scp nix/conf/* root@34.204.71.247:/root/kadena/

###    node3:
* scp nix/conf/* root@54.164.36.85:/root/kadena/

# nix-env to pull kadena files
From each node (nix result taken from CI linux nix bulid):

* nix-env -p /var/lib/kadena/profiles/current --set /nix/store/5lcq6s9baj33rljrydzdnp1y8940cc9s-kadena-1.3.0.0

# Configure kadena service
## Edit each node's /etc/nixos/configuration.nix:
### Add to the open port list:
*  900N (where N is the node number) and all four of 10000, 10001, 10002, 10002
* -- e.g.: networking.firewall.allowedTCPPorts = [ 80 443 9000 10000 10001 10002 10003];

and (using the correct yaml file name per server):
 ``` systemd.services.kadena = {
    enable = true;
    description = "Kadena Node";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    restartIfChanged = true;
    serviceConfig = {
      User = "root";
      KillMode = "process";
      WorkingDirectory = "/var/lib/kadena/run";
      ExecStart = "/var/lib/kadena/profiles/current/bin/kadenaserver +RTS -N4 -RTS -c /root/kadena/1000N-cluster.yaml";
      Restart = "always";
      RestartSec = 5;
      LimitNOFILE = 65536;
    };
  };
```

## Run this for above service to be available:
* sudo -i nixos-rebuild switch

## Check system log for daemon startup errors:
* journalctl -u kadena -f

# Check that kadena is running (replace N with node #)
* tail -f /var/lib/kadena/run/log/nodeN.log

# Restart all 4 nodes' kadena service (from build server)
### from each node:
* systemctl restart kadena

### or remotely:
* systemctl --host=root@54.166.153.21 restart kadena
* systemctl --host=root@54.146.43.204 restart kadena
* systemctl --host=root@34.204.71.247 restart kadena
* systemctl --host=root@54.164.36.85 restart kadena

# nix build automation next steps

1 - same steps as manual, automate as much file copying / editing / directory creating as possible

2 - Define minimal unique info for a given server, minimal unique info for a cluster, drive build from those
    sets of minimal information (including config file generation) -- 4 servers to start

N - generalize to N servers

3 - generate required keys on deployment (for nodes, for private 'entities', etc)
