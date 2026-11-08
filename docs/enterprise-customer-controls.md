# Enterprise operator controls and Desktop acceptance

This is the implementation/acceptance checklist supporting the
[customer installation guide](enterprise-aws-install.md), not a claim that
these controls are already released. Customer-specific requirements, identities,
branding, schedules and advisory notes belong in a private operator handoff.

## Installation-specific policy

Agree the enabled capabilities and operator policy in the private deployment
packet. The public configuration surface should support managed capture,
deterministic pre-upload scrubbing, authorized deletion, installer profiles and
selected add-ons without embedding a customer's identity or business discussion.
Do not infer approval for historical uploads, retention periods or delayed
uploads from a generic example.

## Required admin surface

Use existing customer owner/admin authentication and workspace/organization
authorization. Do not add a second login or a client-side-only privilege flag.
The service owner must specify which actions require owner versus admin and
record that role matrix in the release packet.

- Show the effective capture mode, administrator policy, source, revision and
  enforcement state. Distinguish the policy from a local user's preferences.
- Define policy refresh, cached-policy expiry and offline behavior. A restart,
  reconnect or local settings change must not silently weaken a managed policy.
- Keep deterministic secret scrubbing enforced before outbound session bytes.
  Report a useful failure state without logging the rejected content/secret.
- Provide operator session deletion with explicit target and destructive
  confirmation, permission check, job/status and audit record. Define the
  logical read-denial boundary separately from physical cleanup completion,
  backups, object versions, retries and legal retention.
- Verify revocation/deletion across list, replay, search, catalog/object reads,
  shared/session links and active readers. Replayed ingest must respect the
  approved tombstone/erasure design. Do not weaken pipeline privacy barriers.
- Show health and audit results without exposing application credentials or
  raw session contents in support exports.

Policy transport and storage are application-owned. Helm supplies configuration
and Secret references; a chart cannot enforce Desktop capture policy by itself.

## Customer download URL

The selected human URL is **`https://<customer-app-host>/downloads`**. It is a
required new customer-facing route, not an assertion that the current app
already serves it. Support direct navigation and a visible Download Desktop
link in the normal application. The implementation must work with the app's
existing routing/mount and authentication, including a normal sign-in return.

The page must:

- Identify the approved deployment brand and the exact server address the installer
  connects to; provide an accessible OS/CPU selector and clear install steps.
- Serve only the entitled customer-profile assets from the approved customer
  artifact origin/feed; retain private/no-outbound deployment support.
- Display version, architecture, size, SHA-256 and publisher/signature/trust
  information from verified release metadata. Missing platform assets show a
  clear unavailable state rather than substituting a different build.
- Keep publisher/install credentials out of URLs, page source and browser
  storage. If a download requires a short-lived grant, use the reviewed feed
  contract with server-side authorization and expiry/revocation.
- Bind Desktop's site, deep-link scheme, bundle/application identity and update
  trust to that installation. Do not let a hosted update replace this build.
- Complete download → installation → real Desktop login → own-device approval
  → scrubbed upload → same session visible in the app, on the customer release.

Control's existing
[Desktop feed document](https://github.com/AgentWorkforce/relay-control/blob/92cd27d58df395be050809431f21707016557899/docs/desktop-feed.md)
explicitly says its feed and downloads page are a draft, not implemented. The
existing app Desktop deep-link button is not an installer distribution page.
Release/signing and artifact distribution owners must resolve this contract
before a customer install; this checklist creates no signing keys or tokens.

## Hide and disable an unselected Flows add-on

An installation may select the core profile without Flows. Flows remains an
optional add-on for deployments that select it. Use a server-derived effective capability combining selected
installation configuration and entitlement; the app must not infer permission
from the visibility of a navigation item or a build-time string alone.

| Layer | Required disabled behavior |
| --- | --- |
| Helm | `components.relayflows: false`; no Flows workers or scheduling resources from this release. |
| Control | Effective Flows capability is false; creation/run/schedule/worker and other Flows APIs refuse access under the reviewed status contract. |
| Navigation | Hide Flows and its related worker/run/schedule entry points. Preserve the rest of the sidebar and existing branding. |
| Direct routes | Typing/bookmarking a Flows path shows the disabled/unavailable state; it must not fetch or run Flows resources. |
| Settings/onboarding | No Flows setup, integrations or upsell path for that installation profile. |
| Re-enablement | Only the authorized operator's reviewed configuration/entitlement can enable it; user query parameters/local storage cannot. |

Test both disabled and enabled profiles so this does not remove Flows from
customers who selected it. Check direct API calls in addition to the sidebar.
The current `components.relayflows` Helm toggle alone does not establish these
UI and server behaviors. Coordinate chart/profile versions through the release owner.

## Chief must stay off until explicitly enabled

Apply the same capability, navigation and direct-route rules to Chief. Without
an explicit authorized enablement, the installation must have no Chief agent,
background scans, model calls or scheduled work, and no Chief sidebar entry.
Authenticated direct API/URL requests must report the disabled state rather
than starting work. Test explicit enablement separately.

Chief is the optional service that schedules agent coordination work. The
standalone [`relay-chief` chart](../charts/relay-chief/README.md) now exists and
its CronJob defaults to `suspend: true`; it is not an umbrella
`components.chief` switch. Leave the chart uninstalled for the core pilot.
Suspending a CronJob prevents new jobs, not work already running.

The Control gateway's `503 chief_unavailable` response without a backend is
not an entitlement policy or a complete UI enablement contract. Qualify the
Chief, Control and Webapp configuration together before enabling this add-on.

## Ownership and release evidence

| Work | Implementation owner / coordination |
| --- | --- |
| Customer guide, AWS/Helm packet and profile references | Infrastructure release owner and chart maintainer. |
| First-admin/SSO/device approval, admin authorization and server capabilities | Control service maintainer; coordinate the app integration. |
| App download route, navigation and admin UI | Application maintainer; coordinate the service contracts before implementation. |
| Branded Desktop build, managed capture and client scrubbing | Desktop maintainer. |
| Authorized deletion, storage/index erasure and non-resurrection | Pipeline, History and Control maintainers together. |
| Signed installer distribution/feed | Desktop release owner with Control/artifact-storage owner. |
| Chief capability and optional runtime | Relay Chief maintainer; Control/Webapp maintainers for access and navigation, infrastructure maintainer for the chart/profile. |

Require an exact source SHA, reviewed contract, supported artifact/digest and
causal positive/negative test receipts for each row. A design ACK is not a
released control. Native customer-like end-to-end acceptance remains required.
