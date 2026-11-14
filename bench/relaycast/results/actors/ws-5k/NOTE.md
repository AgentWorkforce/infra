# ws-10k (PG + #657, 4 CPU) connect-only: harness-limited, superseded

Every sink shard stalled at exactly 1,344 sockets (8,064 / 10,000 total) =
21 x 64, the sink's connect concurrency. Under the server's register latency,
agent.register replies timed out after the server had registered the agent; the
retry then got agent_already_exists forever, and once all 64 connect workers were
stuck the shard stopped connecting. Not a server cap (relaycast had 1M fd limit,
8,239 fds open, 638m CPU, 1.8 GiB). The sink now treats that case as bound,
backgrounds slow sockets, and the ws suites bind receivers over HTTP in provision.
The actors ws-5k connect-only result (results/actors/ws-5k) was taken with the
same sink and is superseded the same way.
