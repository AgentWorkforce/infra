# Sessions pipeline

## Native canonical consumer (default off)

`nativeConsumer` supplies a dedicated canonical pointer/Postgres-search consumer
and optional owner bootstrap Job after qualifying the merged source/image and
migration generation. See [the operator contract](../../docs/self-hosted-native-consumer.md)
for its two-pool TLS requirements, separate owner/runtime Secrets, indexer drain
and prepare/serve bootstrap order. No install profile enables it.
