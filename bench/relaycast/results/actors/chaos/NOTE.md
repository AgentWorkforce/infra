# Note on the 9 "duplicate" rows in actors chaos (ch-load)

All 9 are seqs 11-19 of one receiver (workspace 32, r13). They were first
delivered before the gateway was killed (23:45:07Z) and arrived again together
at 23:45:16Z, right after that socket reconnected. The sink in this run assigned
a socket generation only after agent registration had finished, but the engine
re-drains unacked deliveries straight after `node.register`. So these were
counted against the old generation. They are at-least-once redeliveries after
a reconnect, not duplicates on a live socket. The sink now starts a generation
when the socket opens (harness fix in the same commit); true duplicates for
this run: 0.
