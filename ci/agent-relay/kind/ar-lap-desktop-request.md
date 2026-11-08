# ar-lap Desktop candidate request

This is a non-secret proposal for the release owner and Khaliq. No environment,
repository, secret, trust setting or release was created, and no workflow was
dispatched. No qualified local-site Desktop artifact exists yet.

Source checked: relay-desktop main
`6a5216749e6389c5c468db72c7ef2e4356b71e76`, including
[Desktop Release](https://github.com/AgentWorkforce/relay-desktop/blob/6a5216749e6389c5c468db72c7ef2e4356b71e76/.github/workflows/desktop-release.yml)
and its
[site-profile action](https://github.com/AgentWorkforce/relay-desktop/blob/6a5216749e6389c5c468db72c7ef2e4356b71e76/.github/actions/site-profile/action.yml).

## Proposed inputs for review

| Input | Proposed value or missing decision |
| --- | --- |
| Opaque profile id | `q7m2k9`; proposed, not registered |
| GitHub Environment | `desktop-q7m2k9`; not created |
| `DESKTOP_PRODUCT_NAME` | `Agent Relay Kind` |
| `DESKTOP_BUNDLE_ID` | `com.agentrelay.desktop.q7m2k9` |
| `AGENT_RELAY_SITE_URL` | `https://relay.kind.agentrelay.com:8443` |
| `AGENT_RELAY_URL_SCHEME` | `agentrelay-kind` |
| `RELEASES_REPOSITORY` | **Missing owner choice:** an existing public repository dedicated to this profile |
| `RELEASE_FEED` | `github:<the chosen owner/repository>` |
| Telemetry | No key for the current partial fixture; this does not satisfy analytics coverage |
| Branding/support | No custom assets or support URL proposed |
| Candidate mode | `prepare-only=true`, without publication |

The profile action refuses the production feed
`AgentWorkforce/relay-desktop-releases`; it cannot be reused for this candidate.
Its own repository is required even for preparation. A cloud feed is not an
available substitute in the current owner handoff. The release owner must
confirm the profile and identity choices and supply the appropriate existing
credential references. Names only: `DESKTOP_RELEASES_APP_ID` and
`DESKTOP_RELEASES_PRIVATE_KEY`, or `RELEASES_TOKEN`, together with the workflow's
existing signing/notarization inputs. No secret values belong in this document.

After the missing repository decision, environment provisioning and Khaliq's
release go-ahead, the release owner can prepare a candidate with the supported
workflow inputs. The resulting receipt must record the actual source revision,
profile id and artifact hash. The current main SHA is a source-review pin, not
a claim that a future dispatch builds those same bytes.

## History admission and session visibility

Read admission is conditional on a genuine build for the local site and the
authenticated control response naming the exact `history.kind.agentrelay.com:8443`
origin. `history_origin.rs` accepts that workspace origin and records its host;
`deployment_host_with` also permits a cloud-named History host on private/local
addresses when the built-in site differs from the production default. Both the
request-time check and connection resolver use that exception. OS certificate
and hostname verification still apply; no untrusted-origin opt-in is required
or proposed.

Push admission is a separate blocker. `pushed_history_origin` in `cloud/site.rs`
accepts only its two compiled default-port History hosts or loopback HTTP
development. It rejects the kind History origin. Changing the build's site URL
does not widen that rule. A scoped Desktop implementation and tests are needed
before pushed History/flush can work against this local HTTPS origin. No such
runtime qualification is supplied by a profile build.

Only on an operator-designated disposable fixture host, install the fixture
public CA in the System keychain through the operator procedure before native
Desktop/LaunchAgent calls. This CA has no name constraints and must not be
installed on a general workstation. Record its fingerprint; after testing remove
its System-keychain trust and the exact fixture certificate, without touching
unrelated trust roots. Retain the public certificate until removal is verified.
A non-disposable host needs a properly trusted site certificate instead. The
application installs no trust, and this work performs no trust-store change. The current dashboard also reads the legacy History service, while
courier data is in the pipeline database. The compatible pipeline reader,
canonical writer, control auth and upload/read integration gates remain in the
[delivery checklist](ar-lap-delivery-plan.md). A Desktop candidate alone cannot
make newly uploaded sessions visible there.
