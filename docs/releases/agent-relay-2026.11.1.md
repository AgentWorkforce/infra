# agent-relay-2026.11.1: release plan

Status: preparing. This is a draft. Each pin is filled in only once its image is published, provenance-verified and qualified on ar-lap.

| Component | 2026.11.0 | 2026.11.1 target | Gate |
|---|---|---|---|
| relay-control | 0.5.16 | next release including 0.5.18, relay-control#114 (unsupported_storage → 503) and relay-control#116 (optional GitHub-releases downloads source) | #116 merged; image published; migrations run on ar-lap |
| relay-webapp (both containers) | AA pin | image including relay-webapp#133 (Downloads under Settings > Workspace, Usage v2 drill-down), the hard-delete confirm modal, and the releases-repo card fallback | modal and fallback PRs merged; image published |
| sessions services | 77022c5b (relayscrubber alpha.5) | new image from relayhistory-pipeline main after #543 (relayscrubber 0.5.0-alpha.8) | #543 merged; main CI green; image cut on the infra-chief word; alpha.8 confirmed in the image |
| Desktop | 2026.11.7 | 2026.11.8 (alpha.8 + stale-collector fix), separate Desktop feed promote | promote on Khaliq's word after AA's install settles |

Excluded: any image built on relayscrubber alpha.6 or alpha.7 (4cf44e47, e7dded94 withdrawn).

Qualification before tagging: cold ar-lap rebuild on the 2026.11.1 pins (12-check sheet), plus Usage v2 owner/member/audit, the delete-confirm modal, and a Kind downloads card populated from AgentWorkforce/relay-desktop-kind-releases.
