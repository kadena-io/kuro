# Kadena Blockchain Documentation
---

Kadena Version: 1.1.x

# Change Log

* Kadena 1.1.2 (June 12th, 2017)
  * Integrated privacy mechanism (on-chain Noise protocol based private channels)
  * Added `par-batch` to REPL
  * Fixed issues with new command forwarding and batching mechanics
  * `local` queries now execute immediately, skipping the write behind's queue
  * Nodes are automatically configured to run on `0.0.0.0`
  * `genconfs` inputs now are reflected in the configuration files
  * Fixed `genconfs --distributed` 

# Getting Started

### Dependencies

Required:

* `zeromq >= v4.1.4`
  * OSX: `brew install zeromq`
  * Ubuntu: the `apt-get` version of zeromq v4 is incorrect, you need to build it from sounce. See the Ubuntu docker file for more information.
* `libz`: usually this comes pre-installed
* `unixodbc == v3.*`
  * OSX: `brew install unixodbc`
  * Ubuntu: refer to docker file
* Ubuntu Only:
  * `libsodium`: refer to docker file

Optional:

* `rlwrap`: only used in `kadenaclient.sh` to enable Up-Arrow style history. Feel free to remove it from the script if you'd like to avoid installing it.
* `tmux == v2.0`: only used for the local demo script `demo/start.sh`.
A very specific version of tmux is required because features were entirely removed in later version that preclude the script from working.


### Quick Start

Quickly launch a local instance, see "Sample Usage: `[payments|monitor|todomvc]`" for interactions that come with the beta.

#### OSX

```
$ tmux
$ cd kadena-beta
$ ./bin/osx/start.sh
```

#### Ubuntu 16.04

```
$ tmux
$ cd kadena-beta
$ ./bin/ubuntu-16.04/start.sh
```


# Kadena server and client binaries

### `kadenaserver`

Launch a consensus server node.
On startup, `kadenaserver` will open connections on three ports as specified in the configuration file:
`<apiPort>`, `<nodeId.port>`, `<nodeId.port> + 5000`.
Generally, these ports will default to `8000`, `10000`, and `15000` (see `genconfs` for details).

For information regarding the configuration yaml generally, see the "Configuration Files" section.

```
kadenaserver (-c|--config) [-d|--disablePersistence]

Options:
  -c,--config               [Required] path to server yaml configuration file
  -d,--disablePersistence   [Optional] disable usage of SQLite for on-disk persistence
                                       (higher performance)
```

NB: there is a `zeromq` bug that may cause `kadenaserver` to fail to launch (segfault) ~1% of the time. Once running this is not an issue. If you encounter this problem, please relaunch.

### `kadenaclient` & `kadenaclient.sh`

Launch a client to the consensus cluster.
The client allows for command-line level interaction with the server's REST API in a familiar (REPL-style) format.
The associated script incorporates rlwrap to enable Up-Arrow style history, but is not required.

```
kadenaclient (-c|--config)

Options:
  -c,--config               [Required] path to client yaml configuration file

Sample Usage (found in kadenaclient.sh):
  rlwrap -A bin/kadenaclient -c "conf/$(ls conf | grep -m 1 client)"
```

# General Considerations

### Elections Triggered by a High Load

When running a `local` demo, resource contention can trigger election under a high load when certain configurations are present.
For example, `batch 40000` when the replication per heartbeat is set to +10k will likely trigger an election event.
This is caused entirely by a lack of available CPU being present; one of the nodes will hog the CPU, causing the other nodes to trigger an election.
This should not occur in a distributed setting nor is it a problem overall as the automated handling of availability events are one of the features central to any distributed system.

If you would like to do large scale `batch` tests in a local setting, use `genconfs` to create new configuration files where the replication limit is ~8k.

### Load Testing with Many Clients

If you'll be testing with many (100s to +10k) simultaneous clients please be sure to provision extra CPU's.
In a production setting, we'd expect:

* To use a seperate server to collect inbound transactions from the multitude of clients and lump them into a single batch/pipe them over a websocket to the cluster itself so as to avoid needless CPU utilization.
* For clients to connect to different nodes (e.g. all Firm A clients connect to Firm A's nodes, B's to B's, etc.), allowing the nodes themselves to batch/foward commands.

The ability to do either of these is a feature of Kadena -- because commands must have a unique hash and are either (a) signed or (b) fully encrypted, they can be redirected without degrading the security model.

### Replay From Disk

On startup but before `kadenaserver` goes online, it will replay from origin each persisted transaction.
If you would like to start fresh, you will need to delete the SQLite DB's prior to startup.

### Core Count

By default `kadenaserver` is configured use as many cores as are available.
In a distributed setting, this is generally a good default; in a local setting, it is not.
Because each node needs 8 cores to function at peak performance, running multiple nodes locally when clusterSize * 8 > available cores can cause the nodes to obstruct each other (and thereby trigger an election).

To avoid this, the `demo/start.sh` script restricts each node to 4 cores via the `+RTS -N4 -RTS` flags.
You may use these, or any other flags found in [GHC RTS Options](https://downloads.haskell.org/~ghc/7.10.3/docs/html/users_guide/runtime-control.html#rts-opts-compile-time) to configure a given node should you wish to.

* To set cores to a specific amount, add `+RTS -N[core count] -RTS`.
* To allow kadena to use all available cores, do not specify core count (remove the `+RTS -N[count] -RTS` section, or just the `-N[cores]` if using other runtime settings.)

### Beta Limitations

Beta License instances of Kadena are limited as follows:

* The maximum cluster size is limited to 16
* The maximum number of total committed transactions is limited to 200,000
* The binaries will only run for 90 days
* Consensus level membership & key rotation changes are not available

For a version without any/all of these restrictions, please contact us at [info@kadena.io](mailto:info@kadena.io).

# Configuration

### Automated configuration generation: `genconfs`

`kadenaserver` and `kadenaclient` each require a configuration file.
`genconfs` is designed to assist you in quickly (re)generating these files.

It operates in 2 modes:

* `./genconfs` will create a set of config files for a localhost test of kadena.
It will ask you how many cluster and client nodes you'd like.
* `./genconfs --distributed <cluster-ips file>` will create a set of config files using the IP addresses specified in the files.

In either mode `genconfs` will interactively prompt for settings with recommendations.

```
$ ./genconfs
When a recommended setting is available, press Enter to use it
[FilePath] Which directory should hold the log files and SQLite DB's? (recommended: ./log)

Set to recommended value: "./log"
[FilePath] Where should `genconfs` write the configuration files? (recommended: ./conf)
... etc ...
```

In distributed mode:

```
$ cat server-ips
54.73.153.1
54.73.153.2
54.73.153.3
54.73.153.4
$ ./genconfs --distributed ./server-ips
When a recommended setting is available, press Enter to use it
[FilePath] Which directory should hold the log files and SQLite DB's? (recommended: ./log)
... etc ...
```

For details about what each of these configuration choices do, please refer to the "Configuration Files" section.

# Interacting With a Running Cluster

Interaction with the cluster is performed via the Kadena REST API, exposed by each running node.
The endpoints of interest here support the [Pact REST API](http://pact-language.readthedocs.io/en/latest/pact-reference.html#rest-api) for executing transactional and local commands on the cluster.

### The `kadenaclient` tool

Kadena ships with `kadenaclient`, which is a command-line tool for interacting with the cluster via the REST API.
It is an interactive program or "REPL", similar to the command-line itself. It supports command history,
such that recently-issued commands are accessible via the up- and down-arrow keys, and the history can be
searched with Control-R.

#### Getting help

The `help` command documents all available commands.

```
$ ./kadenaclient.sh
node3> help
Command Help:
sleep [MILLIS]
    Pause for 5 sec or MILLIS
cmd [COMMAND]
    Show/set current batch command
data [JSON]
    Show/set current JSON data payload
load YAMLFILE [MODE]
    Load and submit yaml file with optional mode (transactional|local), defaults to transactional
...
```

#### `server` command

Issue `server` to list all nodes known to the client, and `server NODE` to point the client at
the REST API for NODE.

```
node0> server
Current server: node0
Servers:
node0: 127.0.0.1:8000 ["Alice", sending: True]
node1: 127.0.0.1:8001 ["Bob", sending: True]
node2: 127.0.0.1:8002 ["Carol", sending: True]
node3: 127.0.0.1:8003 ["Dinesh", sending: True]
node0> server node1
node1>
```

#### `load` command

`load` is designed to assist with initializing a new environment on a running blockchain,
accepting a yaml file to instruct how the code and data is loaded.

The beta ships with the "demo" smart contract for exploring this:

```
$ tree kadena-beta/payments
payments
├── demo.pact
├── demo.repl
└── demo.yaml

$ cat kadena-beta/payments/demo.yaml
data: |-
  { "demo-admin-keyset": { "keys": ["demoadmin"], "pred": ">" } }
codeFile: demo.pact
keyPairs:
  - public: 06c9c56daa8a068e1f19f5578cdf1797b047252e1ef0eb4a1809aa3c2226f61e
    secret: 7ce4bae38fccfe33b6344b8c260bffa21df085cf033b3dc99b4781b550e1e922
batchCmd: |-
  (demo.transfer "Acct1" "Acct2" 1.00)

```

#### Sample Usage: running the payments demo (non-private) and testing batch performance

Launch the client and (optionally) target the leader node (in this case `node0`).
The only reason to target the leader is to forgo the forwarding of new transactions to the leader.
The cluster will handle the forwarding automatically.

```
cd kadena-beta
./bin/osx/kadenaclient.sh
node3> server node0
```

Initialize the chain with the `demo` smart contract, and create the global/non-private accounts.
Note that the load process has an optional feature to set the batch command (see docs for `cmd` in help).
The demo.yaml sets the batch command to
transfer `1.00` between the demo accounts.

```
node0> load payments/demo.yaml
status: success
data: Write succeeded

Setting batch command to: (demo.transfer "Acct1" "Acct2" 1.00)
node0> exec (demo.create-global-accounts)
account      | amount       | balance      | data
---------------------------------------------------------
"Acct1"      | "1000000.0"  | "1000000.0"  | "Admin account funding"
"Acct2"      | "0.0"        | "0.0"        | "Created account"
```
Execute a single dollar transfer and check the balances again with `read-all`. `exec` sends
a command to execute transactionally on the blockchain; `local` queries the local node (here "node0")
to prevent a needless transaction for a query.

```
node0> exec (demo.transfer "Acct1" "Acct2" 1.00)
status: success
data: Write succeeded

node0> local (demo.read-all)
account      | amount       | balance      | data
---------------------------------------------------------
"Acct1"      | "-1.00"      | "999999.00"  | {"transfer-to":"Acct2"}
"Acct2"      | "1.00"       | "1.00"       | {"transfer-from":"Acct1"}
```

Verify that `cmd` is properly setup, and perform a `batch` test.
`batch N` will create N identical transactions, using the command specified in `cmd` for each, and then send them to the cluster via the server specified by `server` (in this case to `node0`).

Once sent, the client will then `listen` for the final transaction, collect and show its timing metrics, and print out the throughput seen in the test (i.e. `"Finished Commit" / N`).
The "First Seen" time is the moment when the targeted server first saw the **batch** of transactions and the "Finished Commit" time delta fully captures the time it took for the replication, consensus, cryptography, and execution of the final transaction (meaning that all previous transactions needed to first be fully executed.)

Some of the metrics may be of interest to you:

```
node0> cmd
(demo.transfer "Acct1" "Acct2" 1.00)
node0> batch 4000
Preparing 4000 messages ...
Sent, retrieving responses
Polling for RequestKey: "b768a85c6e1a06d4cfd9760dd981b675dcd9dc97ee8d7abc756246107f2ea03edd80e10e5168b41ee96a17b098ea3285a0f5ca9c61c4d974a7832e01f354dcf9"
First Seen:          2017-03-19 05:43:14.571 UTC
Hit Turbine:        +24.03 milli(s)
Entered Con Serv:   +39.83 milli(s)
Finished Con Serv:  +52.41 milli(s)
Came to Consensus:  +113.00 milli(s)
Sent to Commit:     +113.94 milli(s)
Started PreProc:    +690.55 milli(s)
Finished PreProc:   +690.66 milli(s)
Crypto took:         115 micro(s)
Started Commit:     +1.51 second(s)
Finished Commit:    +1.51 second(s)
Pact exec took:      179 micro(s)
Completed in 1.517327sec (2637 per sec)
node0> exec (demo.read-all)
account      | amount       | balance      | data
---------------------------------------------------------
"Acct1"      | "-1.00"      | "995999.00"  | {"transfer-to":"Acct2"}
"Acct2"      | "1.00"       | "4001.00"    | {"transfer-from":"Acct1"}
```
If you would like to view the performance metrics from each node in the cluster, this can be done via `pollMetrics <requestKey>`


```
node0> pollMetrics b768a85c6e1a06d4cfd9760dd981b675dcd9dc97ee8d7abc756246107f2ea03edd80e10e5168b41ee96a17b098ea3285a0f5ca9c61c4d974a7832e01f354dcf9
##############  node3  ##############
First Seen:          2017-03-19 05:43:14.571 UTC
Hit Turbine:        +24.03 milli(s)
Entered Con Serv:   +39.83 milli(s)
Finished Con Serv:  +52.41 milli(s)
Came to Consensus:  +113.00 milli(s)
Sent to Commit:     +113.94 milli(s)
Started PreProc:    +690.55 milli(s)
Finished PreProc:   +690.66 milli(s)
Crypto took:         115 micro(s)
Started Commit:     +1.51 second(s)
Finished Commit:    +1.51 second(s)
Pact exec took:      179 micro(s)
##############  node2  ##############
First Seen:          2017-03-19 05:43:14.868 UTC
... etc ...
```

NB: the `Crypto took` metric is only accurate when the concurrency system is set to `Threads`.
All other metrics are always accurate.

#### Sample Usage: Stressing the Cluster

The aforementioned performance test revolves around the idea that, in production, there will be a resource pool that batches new commands and forwards them directly to the Leader for the cluster.
This is, by far, the best architectural setup from a performance and efficiency perspective.
However, if you'd like to test the worst-case setup -- one where new commands are distributed evenly across the cluster and the cluster is forced to forward and batch them as best it can -- you can use `par-batch`.

`par-batch TOTAL_CMD_CNT CMD_RATE_PER_SEC DELAY` works much like `batch` except that `kadenaclient` will evenly distributed the new commands across the entire cluster.
It is creates `TOTAL_CMD_CNT` commands first and then submits portions of the new command pool to each node in individual batches with a `DELAY` millisecond pause between each submission.
Globally, it will achieve the `CMD_RATE_PER_SEC` specified. 

For example, on a 4 node cluster `par-batch 10000 1000 200` will submit 50 new commands to each node every 200ms for 10 seconds.

NB: In-REPL performance metrics for this test are inaccurate.
Also, being the worst case architecture means that the cluster will make a best effort at performance but it will not be as high as `batch`.


#### Sample Usage: Running the payments demo with private functionality

Refer to "Entity Configuration" below for general notes on privacy configurations. This demo requires that there be 4 entities configured by the `genconfs` tool, which will name them "Alice", "Bob", "Carol" and "Dinesh". These would correspond to business entities on the blockchain, communicating with private messages over the blockchain. Confirm this setup with the `server` command.

Launch the cluster, and load the demo.yaml file.

```
node3> load demo/demo.yaml
status: success
data: TableCreated

Setting batch command to: (demo.transfer "Acct1" "Acct2" 1.00)
```

Create the private accounts by sending a _private message_ that executes a multi-step _pact_ to create private accounts on each entity. Change to Alice's server (node0) and send a private message to the other 3 participants with the demo code:

```
node3> server node0
node0> private Alice [Bob Carol Dinesh] (demo.create-private-accounts)
```

The `private` command creates an encrypted message, sent from Alice to Bob, Carol and Dinesh. The `create-private-accounts` pact executes a single command on the different servers. To see the results, perform _local queries_ on each node.

```
node0> local (demo.read-all)
account | amount   | balance  | data
-------------------------------------------------
"A"     | "1000.0" | "1000.0" | "Created account"
node0> server node1
node1> local (demo.read-all)
account | amount   | balance  | data
-------------------------------------------------
"B"     | "1000.0" | "1000.0" | "Created account"
node1> server node2
node2> local (demo.read-all)
account | amount   | balance  | data
-------------------------------------------------
"C"     | "1000.0" | "1000.0" | "Created account"
node2> server node3
node3> local (demo.read-all)
account | amount   | balance  | data
-------------------------------------------------
"D"     | "1000.0" | "1000.0" | "Created account"
```

This illustrates how the different servers (which would be presumably behind firewalls, etc) contain different, private data.

Now, execute a confidential transfer between Alice and Bob, transfering money from Alice's account "A" to Bob's account "B".

For this, the pact "payment" is used, which executes the debit step on the "source" entity, and the credit step on the "dest" entity. You can see the function docs by simply executing `payment`:

```
node3> local demo.payment
status: success
data: (TDef defpact demo.payment (src-entity:<i> src:<j> dest-entity:<k> dest:<l>
  amount:<m> -> <n>) "Two-phase confidential payment, sending money from SRC at SRC-ENTITY
  to DEST at DEST-ENTITY.")
```

Set the server to node0 for Alice, and execute the pact to send 1.00 to Bob:

```
node3> server node0
node0> private Alice [Bob] (demo.payment "Alice" "A" "Bob" "B" 1.00)
status: success
data:
  amount: '1.00'
  result: Write succeeded
```

To see the results, issue local queries on the nodes. Note that node2 and node 3 are unchanged:

```
node0> local (demo.read-all)
account | amount  | balance  | data
----------------------------------------------------------------------------
"A"     | "-1.00" | "999.00" | {"tx":5,"transfer-to":"B","message":"Starting pact"}
node0> server node1
node1> local (demo.read-all)
account | amount | balance   | data
-------------------------------------------------------------------------------------
"B"     | "1.00" | "1001.00" | {"tx":5,"debit-result":"Write succeeded","transfer-from":"A"}
node1> server node2
node2> local (demo.read-all)
account | amount   | balance  | data
-------------------------------------------------
"C"     | "1000.0" | "1000.0" | "Created account"
node2> server node3
node3> local (demo.read-all)
account | amount   | balance  | data
-------------------------------------------------
"D"     | "1000.0" | "1000.0" | "Created account"
```

You can also test out the rollback functionality on an error. Mistype the recipient account id (in this case we use "bad" instead of "B"). The pact will execute the debit on Alice/node0; attempt the credit on Bob/node1, failing because of the bad ID; finally the rollback will execute on Alice/node0. Bob's account will be unchanged, while Alice's account will note the rollback with the original tx id of the pact execution.

```
node0> private Alice [Bob] (demo.payment "Alice" "A" "Bob" "bad" 1.00)
status: success
data:
  tx: 7
  amount: '1.00'
  result: Write succeeded

node0> local (demo.read-all)
account | amount | balance  | data
--------------------------------------------
"A"     | "1.00" | "999.00" | {"rollback":7}
node0> server node1
node1> local (demo.read-all)
account | amount | balance   | data
--------------------------------------------------------------------------------------------
"B"     | "1.00" | "1001.00" | {"tx":5,"debit-result":"Write succeeded","transfer-from":"A"}
```

NB: The result of the first send shows you the result of the first part of the multi-phase tx, thus the "success"/"Write succeeded" status. Querying the database reveals the rollback which occurred two transactions later.


#### Sample Usage: Viewing the Performance Monitor

Each kadena node, while running, will host a performance monitor at the URL `<nodeId.host>:<nodeId.port>/monitor`.

#### Sample Usage: Running Pact TodoMVC

The `kadena-beta` also bundles the [Pact TodoMVC](github.com/kadena-io/pact-todomvc). Each kadena node will host the frontend at `<nodeId.host>:<nodeId.port>/todomvc`. To initialized the `todomvc`:

```
$ cd kadena-beta

# launch the cluster

$ ./bin/osx/kadenaclient.sh
node3> load todomvc/demo.yaml

# go to host:port/todomvc
```

NB: this demo can be run at the same time as the `payments` demo.

#### Sample Usage: Running a cluster on AWS

The scripts we use for quickly testing Kadena on AWS are now available as well, located in `kadena-beta/scripts`.
The include: 

* `create_aws_confs.sh`: This script will query AWS for a list of IP addresses, use it to create the configs for each node (and one client), and create a file directory `aws-confs` that stores the configs and the startup scripts for each node.
* `servers.sh`: This script is used for managing the cluster and requires the `aws-confs` file hierarchy to be in place prior to running. It can distribute the `kadenaserver` binaries to each node, configure each server (transfer configs, start scripts, create directories), start/stop/reset the cluster, query the status of each node, etc... View the source for more details. 

#### Sample Usage: Querying the Cluster for Server Metrics

Each `kadenaserver` hosts an instance of `ekg` (a performance monitoring tool) on `<node-host>:<node-port>+80`. 
It returns a JSON blob of the latest tracked metrics. 
`server.sh status` uses this mechanism for status querying:

```
status)
  for i in `cat kadenaservers.privateIp`;
    do echo $i ; 
      curl -sH "Accept: application/json" "$i:10080" | jq '.kadena | {role: .node.role.val, commit_index: .consensus.commit_index.val, applied_index: .node.applied_index.val}' ; 
    done
  exit 0
  ;;

```

NB: The `port` that `genconfs` when running in `--distributed` mode is `10000` therefore `ekg` runs on port `10080` on each node.

# Configuration File Documentation

Generally, you won't need to personally edit the configuration files for either the client or server(s), but this information is available should you wish to.
The executable `genconfs` will create the configuration files for you and offer recommended settings based on your choices.

## Server (node) config file

### Node Specific Information

#### Identification

Each consensus node requires a unique Ed25519 keypair and `nodeId`.

```
myPublicKey: 53db73154fbb0c57129a0029439e5fc448e1199b6dcd5601bc08b48c5d9b0058
myPrivateKey: 0c2b9f177cee13c698bec6afe2e635ca244ce402ccbd826a483f25f618beec8f
nodeId:
  alias: node0
  fullAddr: tcp://127.0.0.1:10000
  host: '127.0.0.1'
  port: 10000
```

#### Other Nodes

Each consensus node further requires a map of every other node, as well as their associated public key.

```
otherNodes:
- alias: node1
  fullAddr: tcp://127.0.0.1:10001
  host: '127.0.0.1'
  port: 10001
- alias: node2
  fullAddr: tcp://127.0.0.1:10002
  host: '127.0.0.1'
  port: 10002
- alias: node3
  fullAddr: tcp://127.0.0.1:10003
  host: '127.0.0.1'
  port: 10003

publicKeys:
- - node0
  - 53db73154fbb0c57129a0029439e5fc448e1199b6dcd5601bc08b48c5d9b0058
- - node1
  - 65d59bda770dd6de2b25308b2e039714fec752e42d11af3712159f27e9e295f4
- - node2
  - bd1700e6f206315debabfa5bf42228ed4f9e78cacbffabcca74ff4f67e5ac7a4
- - node3
  - 8d6f928659ea57be2ac19d64af05ca0ccb0f42303f0d668d1263c9a4c8b36925
```

#### Runtime Configuration

Kadena uses SQLite for caching & persisting various by default.
Upon request, Oracle, MS SQL Server, Postgres, and generic ODBC backends are also available.

* `apiPort`: what port to host the REST API identical to the [Pact development server](http://pact-language.readthedocs.io/en/latest/pact-reference.html#rest-api)
* `logDir`: what directory to use for writing the HTTP logs, the Kadena logs, and the various SQLite databases.
* `enableDebug`: should the node write any logs

While this is pretty low level tuning, Kadena nodes can be configured to use different concurrency backends.
We recommend the following defaults but please reach out to us if you have questions about tuning.

```
preProcUsePar: true
preProcThreadCount: 100
```

### Consensus Configuration

These settings should be identical for each node.

* `aeBatchSize:<int>`: This is the maximum number of transactions a leader will attempt to replicate at every heartbeat. It's recommended that this number average out to 10k/s.
* `inMemTxCache:<int>`: How many committed transactions should be kept in memory before only being found on disk. It's recommended that this number be x10-x60 the `aeBatchSize`. This parameter impacts memory usage.
* `heartbeatTimeout:<microseconds>`: How often should the Leader ping its Followers. This parameter should be at least 2x the average roundtrip latency time of the clusters network.
* `electionTimeoutRange:[<min::microseconds>,<max::microseconds>]`: Classic Raft-Style election timeouts.
  * `min` should be >= 5x of `heartbeatTimeout`
  * `max` should be around `min + (heartbeatTimeout*clusterSize)`.

### Entity Configuration and Confidentiality

The Kadena platform uses the [Noise protocol](http://noiseprotocol.org/) to provide the best possible on-chain encryption, as used by Signal, Whatsapp and Facebook. Messages are thoroughly encrypted with perfect forward secrecy, resulting in opaque blobs on-chain that leak no information about contents, senders or recipients.

Configuring for confidential execution employs the notion of "entities", which identify sub-clusters of nodes as belonging to a business entity with private data. Entities maintain keys for encrypting as well as signing.

Within an entity sub-cluster, a single node is configured as a "sending node" which must be used to initiate private messages; this allows other sub-cluster nodes to avoid race conditions surrounding the key "ratcheting" used by the Noise protocol for forward secrecy; this way sub-cluster nodes will stay perfectly in sync and replicate properly.

For a given entity, the `signer` and `local` entries must match for all nodes in the sub-cluster; only one may be designated as `sender` setting that to `true` for that node only. `remotes` list the static public key and the entity name for each remote entity in the cluster.

The `signer` private and public keys are ED25519 signing keys; the `secret` and `public` keys for local ephemeral and static keys, as well as for remote public keys, are Curve25519 Diffie-Hellman keys.


### Performance Considerations

While `genConfs` will make a best guess at what the best configuration for your cluster is based on your inputs, it may be off. To that end, here are some notes if you find yourself seeing unexpected performance numbers.

The relationship of `aeBatchSize` to `heartbeatTimeout` determines the upper bound on performance, specifically `aeBatchSize/heartbeatTimeoutInSeconds = maxTransactionsPerSecond`.
This is because when the cluster has a large number of pending transactions to replicate, it will replicate up to `aeBatchSize` transactions every heartbeat until the cluster has caught up.
Generally, it's best to have `maxTransactionsPerSecond` be 1.5x of the expected performance, which itself is ~8k/second.

Because of the way that we measure performance, which starts from the moment that the cluster's Leader node first sees a transaction to when it fully executes the Pact smart contract (inclusive of the time required for replication, consensus, and cryptography), the logic of the Pact smart contract itself will impact performance.
Thus, executing simple logic like `(+ 1 1)` will achieve 12k commits/second whereas a smart contract with numerous database writes will vary based on the backend used and the complexity of the data model.


## Client (repl) config file

Example of the client (repl) configuration file. `genconfs` will also auto-generate this for you.

```
PublicKey: 53db73154fbb0c57129a0029439e5fc448e1199b6dcd5601bc08b48c5d9b0058
SecretKey: 0c2b9f177cee13c698bec6afe2e635ca244ce402ccbd826a483f25f618beec8f
Endpoints:
  node0: 127.0.0.1:8000
  node1: 127.0.0.1:8001
  node2: 127.0.0.1:8002
  node3: 127.0.0.1:8003
```

(c) Kadena 2017
