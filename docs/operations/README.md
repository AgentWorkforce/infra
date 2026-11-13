# Self-hosted operations contract

This directory defines the measurable production gates for the self-hosted
Agent Relay supported tier. It is a release contract, not evidence that the
current chart has passed the gates.

## Product commitments

| Commitment | Contract |
|---|---|
| Availability | 99.9% per calendar month |
| Supported tier | 100 users, 50 concurrently connected agents, 10,000 sessions/day |
| Recovery | RPO at most 15 minutes; RTO at most 4 hours |
| Server versions | Current release (`N`) and previous release (`N-1`) |
| Desktop versions | Current and previous release on every customer platform |

The availability error budget is 0.1% of eligible operations in a calendar
month. For intuition only, a continuous time-based SLI would allow 40.32,
41.76, 43.20, or 44.64 minutes in a 28-, 29-, 30-, or 31-day month. The
request-based budget is calculated from actual eligible operations and is not
converted to downtime for release approval.

## Release status

The current GCP chart values are a sizing hypothesis. Several components are
intentionally single-replica or single-writer. Resource requests alone cannot
establish 99.9% availability, and no benchmark result is claimed here.
Customer release remains blocked until evidence from the exact chart version
and image manifest passes every gate below.

1. [Service levels and SLIs](service-level-objectives.md)
2. [Capacity hypotheses and load-test gates](capacity-and-load-test.md)
3. [Runbook: Relaycast from PostgreSQL to durable-actors](relaycast-actors-upgrade-runbook.md)

Backup and restore mechanics are documented in the existing
[backup and restore runbook](../selfhost-backup-restore.md). That procedure is
not proof of the 15-minute RPO or 4-hour RTO until a timed drill passes.
