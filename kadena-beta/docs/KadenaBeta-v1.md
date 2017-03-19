# Kadena Blockchain Documentation
---


#### Version

Kadena Binary: 1.0 - 2.0

Documentation: v1


# Getting Started

### Dependencies

Required:

* `zeromq >= v4.1.4`
* `libz` -- LZMA Compression Library

Optional:

* `rlwrap`: only used in `kadenaclient.sh` to enable Up-Arrow style history. Feel free to remove it from the script if you'd like to avoid installing it.
* `tmux == v2.0`: only used for the local demo script `demo/start.sh`.
A very specific version of tmux is required because features were entirely removed in later version that preclude the script from working.


### Quick Start



### Binaries

#### `kadenaserver`

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

#### `kadenaclient` & `kadenaclient.sh`

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

#### Things to be aware of

##### Elections Triggered by a High Load

When running a `local` demo, resource contention can trigger election under a high load when certain configurations are present.
For example, `batch 40000` when the replication per heartbeat is set to +10k will likely trigger an election event.
This is caused entirely by a lack of available CPU being present; one of the nodes will hog the CPU, causing the other nodes to trigger an election.
This should not occur in a distributed setting nor is it a problem overall as the automated handling of availability events are one of the features central to any distributed system.

If you would like to do large scale `batch` tests in a local setting, use `genconfs` to create new configuration files where the replication limit is ~8k.

##### Replay From Disk

On startup but before `kadenaserver` goes online, it will replay from origin each persisted transaction.
If you would like to start fresh, you will need to delete the SQLite DB's prior to startup.

##### Core Count

By default `kadenaserver` is configured use as many cores as are available.
In a distributed setting, this is generally a good default; in a local setting, it is not.
Because each node needs 8 cores to function at peak performance, running multiple nodes locally when clusterSize * 8 > available cores can cause the nodes to obstruct each other (and thereby trigger an election).

To avoid this, the `demo/start.sh` script restricts each node to 4 cores via the `+RTS -N4 -RTS` flags.
You may use these, or any other flags found in [GHC RTS Options](https://downloads.haskell.org/~ghc/7.10.3/docs/html/users_guide/runtime-control.html#rts-opts-compile-time) to configure a given node should you wish to.

##### Beta Limitations

Beta License instances of Kadena are limited in the following ways:

* The maximum cluster size is limited to 16
* The maximum number of total committed transactions is limited to 200,000
* The binaries will only run for 90 days
* Consensus level membership & key rotation changes are not available

For a version without any/all of these restrictions, please contact us at [info@kadena.io](mailto:info@kadena.io).

##### Performance Limitations

Currently the peak performance of Kadena v1 has degraded to ~4k/second for our "Payments Performance Demo" (vs Kadena v0's 8k/sec).
While unfortunate, we are aware of the  on the cause of the slowdown and should have full performance returned by mid April.
We apologize for the inconvenience.

### Automated configuration generation: `genconfs`

`kadenaserver` and `kadenaclient` each require a configuration file.
`genconfs` is designed to assist you in quickly (re)generating these files.

It operates in 2 modes:

* `./genconfs` will create a set of config files for a localhost test of kadena.
It will ask you how many cluster and client nodes you'd like.
* `./genconfs --distributed <cluster-ips file> <client-ips file>` will create a set of config files using the IP addresses specified in the files.

In either mode `genconfs` will try to recommend the right settings as you specify your environment:

```
$ ./genconfs
When a recommended setting is available, press Enter to use it
[FilePath] Which directory should hold the log files and SQLite DB's? (recommended: ./log)

Set to recommended value: "./log"
[FilePath] Where should `genconfs` write the configuration files? (recommended: ./conf)

Set to recommended value: "./conf"
[Integer] Number of consensus servers?
4
[Integer] Number of clients?
1
[Integer] Leader's heartbeat timeout (in seconds)? (recommended: 2)

Set to recommended value: 2
[Integer] Election timeout min in seconds? (recommended: 10)

Set to recommended value: 10
[Integer] Election timeout max in seconds? (recommended: >=18)

Set to recommended value: 18
[Integer] Pending transaction replication limit per heartbeat? (recommended: 20000)

Set to recommended value: 20000
[Integer] How many committed transactions should be cached? (recommended: 200000)

Set to recommended value: 200000
[Sparks|Threads] Should the Crypto PreProcessor use spark or green thread based concurrency? (recommended: Sparks)

Set to recommended value: Sparks
[Integer] How many transactions should the Crypto PreProcessor work on at once? (recommended: 100)

Set to recommended value: 100

```
In distributed mode:

```
$ cat server-ips
54.73.153.1
54.73.153.2
54.73.153.3
54.73.153.4
$ cat client-ips
54.73.153.5
$ ./genconfs --distributed ./server-ips ./client-ips
When a recommended setting is available, press Enter to use it
[FilePath] Which directory should hold the log files and SQLite DB's? (recommended: ./log)
... etc ...
```

For details about what each of these configuration choices do, please refer to the "Configuration Files" section.

# Interacting With a Running Cluster

All interaction with the cluster is done via a REST API.
The REST API is identical to the [Pact development server](http://pact-language.readthedocs.io/en/latest/pact-reference.html#rest-api) API with the exception that every node will host it's own instance.
You may interact with any node's API. Indeed, this is what `kadenaclient` itself does.

### Via the `kadenaclient` REPL

While simple to use/interact with, there are a lot of details for more advance usage.
Please contact us on slack if there topics you'd like dive deeper into than we detail here.
To begin, when the REPL is running there are a number of REPL specific commands are available:

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
batch TIMES
    Repeat command in batch message specified times
pollMetrics REQUESTKEY
    Poll each server for the request key but print latency metrics from each.
poll REQUESTKEY
    Poll server for request key
exec COMMAND
    Send command transactionally to server
local COMMAND
    Send command locally to server
server [SERVERID]
    Show server info or set current server
help
    Show command help
keys [PUBLIC PRIVATE]
    Show or set signing keypair
exit
    Exit client
format [FORMATTER]
    Show/set current output formatter (yaml|raw|pretty)
```

`load` is designed to assist with initializing a new environment on a running blockchain.
Here is an example load yaml file:

```
$ tree demo
demo
├── demo.pact
├── demo.repl
└── demo.yaml

$ cat demo/demo.yaml
data: |-
  { "demo-admin-keyset": { "keys": ["demoadmin"], "pred": ">" } }
codeFile: demo.pact
keyPairs:
  - public: 06c9c56daa8a068e1f19f5578cdf1797b047252e1ef0eb4a1809aa3c2226f61e
    secret: 7ce4bae38fccfe33b6344b8c260bffa21df085cf033b3dc99b4781b550e1e922
batchCmd: |-
  (demo.transfer "Acct1" "Acct2" 1.00)

```

#### Sample Usage: running the payments demo

Launch the client and (optionally) target the leader node (in this case `node0`).
The only reason to target the leader is to forgo the forwarding of new transactions to the leader.
The cluster will handle the forwarding automatically.

```
./kadenaclient.sh
node3> server node0
```
Initialize the chain (for the Payments performance demo) and read the intial balances.
When initialized, the `cmd` is set to a single dollar transfer.

```
node0> load demo/demo.yaml
status: success
data: Write succeeded

Setting batch command to: (demo.transfer "Acct1" "Acct2" 1.00)
node0> exec (demo.read-all)
account      | amount       | balance      | data
---------------------------------------------------------
"Acct1"      | "1000000.0"  | "1000000.0"  | "Admin account funding"
"Acct2"      | "0.0"        | "0.0"        | "Created account"
```
Execute a single dollar transfer and check the balances again.

```
node0> exec (demo.transfer "Acct1" "Acct2" 1.00)
status: success
data: Write succeeded

node0> exec (demo.read-all)
account      | amount       | balance      | data
---------------------------------------------------------
"Acct1"      | "-1.00"      | "999999.00"  | {"transfer-to":"Acct2"}
"Acct2"      | "1.00"       | "1.00"       | {"transfer-from":"Acct1"}
```
Verify that `cmd` is properly setup and perform a `batch` test.
`batch N` will create N identical transactions, using the command specified in `cmd` for each, and then send them to the cluster via the server specified by `server` (in this case to `node0`).

Once sent, the REPL will then `listen` for the final transaction, collect and show its timing metrics, and print out the throughput seen in the test (i.e. `"Finished Commit" / N`).
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



# Configuration Files

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

### Performance Considerations

While `genConfs` will make a best guess at what the best configuration for your cluster is based on your inputs, it may be off. To that end, here are some notes if you find yourself seeing unexpected performance numbers.

The relationship of `aeBatchSize` to `heartbeatTimeout` determines the upper bound on performance, specifically `aeBatchSize/heartbeatTimeoutInSeconds = maxTransactionsPerSecond`.
This is because when the cluster has a large number of pending transactions to replicate, it will replicate up to `aeBatchSize` transactions every heartbeat until the cluster has caught up.
Generally, it's best to have `maxTransactionsPerSecond` be 1.5x of the expected performance, which itself is ~8k/second.

Because of the way that we measure performance, which starts from the moment that the cluster's Leader node first sees a transaction to when it fully executes the Pact smart contract (inclusive of the time required for replication, consensus, and cryptography), the logic of the Pact smart contract itself will impact performance.
For example, the "smart contract" `(+ 1 1)` will execute at a rate of 12k/second whereas a smart contract that requires 1 second to fold a protein will execute at 1/second.
In both cases, the performance of everything up to the point of execution will be identical.


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
