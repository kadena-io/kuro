# Kadena Blockchain Documentation
---


#### Version

Kadena Binary: 1.0 - 2.0

Documentation: v1


# Getting Started

## Some basics

### Automated configuration generation: `genconfs`

`kadenaserver` and `kadenaclient` each require a configuration file. 
`genconfs` is designed to assit you in quickly (re)generating these files.

It operates in 2 modes:

* `./genconfs` will create a set of config files for a localhost test of kadena. 
It will ask you how many cluster and client nodes you'd like.
* `./genconfs --distributed <cluster-ips file> <client-ips file>` will create a set of config files using the IP addresses specified in the files.

Once started, `genconfs` will try to recommend the right settings for your environment:

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

For details about what each of these configuration choices do, please refer to the "Configuration Files" section.


# Configuration Files

Generally, you won't need to personally edit the configuration files for either the client or server(s), but this information is available should you wish to. 
The executable `genconfs` will create the configuration files for you and offer recommended settings based on your choices.

## Server (node) config file

### Node Specific Information

#### Indentification

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

While `genConfs` will make a best guess at what the best configurion for your cluster is based on your inputs, it may be off. To that end, here are some notes if you find yourself seeing unexpected performance numbers.

The relationship of `aeBatchSize` to `heartbeatTimeout` determines the upper bound on performance, specifically `aeBatchSize/heartbeatTimeoutInSeconds = maxTransactionsPerSecond`. 
This is because when the cluster has a large number of pending transactions to replicate, it will replicate up to `aeBatchSize` transactions every heartbeat until the cluster has caught up. 
Generally, it's best to have `maxTransactionsPerSecond` be 1.5x of the expected performance, which itself is ~8k/second.

Because of the way that we measure performance, which starts from the moment that the cluster's Leader node first sees a transaction to when it fully executes the Pact smart contract (inclusive of the time required for replication, consensus, and cryptography), the logic of the Pact smart contract itself will impact performance.
For example, the "smart contract" `(+ 1 1)` will execute at a rate of 12k/second whereas a smart contract that requires 1 second to fold a protein will execute at 1/second. 
In both cases, the performance of everything up to the point of execution will be identitical.

NB: The upgrade from Pact 1 to Pact 2 (in Janruary) the performance of our "payments demo" has dropped from 8k/s to 4k/s. 
We expect to have regained the performance by April.
 

## Client (repl) config file

Example of the client (repl) configuration file. `genconfs` will also autogenerate this for you.

```
PublicKey: 53db73154fbb0c57129a0029439e5fc448e1199b6dcd5601bc08b48c5d9b0058
SecretKey: 0c2b9f177cee13c698bec6afe2e635ca244ce402ccbd826a483f25f618beec8f
Endpoints:
  node0: 127.0.0.1:8000
  node1: 127.0.0.1:8001
  node2: 127.0.0.1:8002
  node3: 127.0.0.1:8003
```
