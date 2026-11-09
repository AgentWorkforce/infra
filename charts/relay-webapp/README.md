# relay-webapp

Public chart names and existing-release compatibility: [Control/Webapp rename](../../docs/control-webapp-chart-rename.md).

Deploys the self-hosted Agent Relay dashboard container. The image digest is
required; this chart never follows a tag and does not create Secrets. Runtime
settings are passed with `DASHBOARD_PUBLIC_URL`, `DASHBOARD_APP_PATH`,
`DASHBOARD_API_BASE_PATH`, and `DASHBOARD_LOGIN_PATH`.

The browser calls `runtime.apiBasePath` (default `/cloud/api`) on its current
origin. When ingress is enabled, the chart routes `runtime.apiBasePath` and
`runtime.loginPath` to `api.serviceName` and `/` to the dashboard.
`api.serviceName` has no default and is required with ingress: set it to the
relay-control Service in the same namespace, which is that release's
fullname (`<release>-relay-control`, or its `fullnameOverride`; for example
`api-relay-control` after `helm install api charts/relay-control`). The separate
`relay-control` ingress can expose that same Service on an `api.` host.

Single-host mode: with `global.singleHost.host` set (normally once on the
agent-relay umbrella), `runtime.publicUrl` is derived as `https://<host>` and
`ingress.host` as `<host>` (leave them empty), and the Ingress also routes
`/api` to the API, because flows workers and the integrations OAuth callback
call `<publicUrl>/api/v1/...` there. Keep the `relay-control` ingress
disabled in that mode. See the agent-relay README, "Single-host mode".

The current dashboard image is a single static replica. This chart makes no HA
claim. Publish and verify the dashboard image before replacing the digest in a
deployment values file.

## Customer profile (branding)

`customerProfile` rebrands the dashboard for an enterprise customer without a
new image. The chart renders it as JSON into `DASHBOARD_CUSTOMER_PROFILE`; the
image writes it into `/runtime-config.js`, and the browser validates each field
and ignores any it can't use. Leave it empty (the default) to keep the Agent
Relay look. It needs a dashboard image built from relay-webapp
[#84](https://github.com/AgentWorkforce/relay-webapp/pull/84) or later (the
image's `/runtime-config.js` then contains a `customerProfile` key); older
images ignore the value.

| key | meaning |
| --- | --- |
| `customerProfile.productName` | Product name shown instead of "Agent Relay" (sidebar text when there is no logo, labels, device page). |
| `customerProfile.title` | Browser tab title (defaults to `productName`). |
| `customerProfile.logo` | Either a map with `light` and `dark` URLs, or one URL string used for both themes. Replaces the mark and wordmark. |
| `customerProfile.logo.light` / `.dark` | Logo URL for the light and dark themes when `logo` is a map. |
| `customerProfile.favicon` | Favicon URL. |
| `customerProfile.accentColor` | Accent for links, focus rings and active navigation (`#hex`, `rgb()`, `hsl()`, `oklch()`). |
| `customerProfile.brandColor` | Solid primary button color. |
| `customerProfile.supportUrl` | Support link in the account menu and on the device page (`https://…` or `mailto:`). |
| `customerProfile.poweredByAgentRelay` | `false` hides the "Powered by Agent Relay" line shown under a custom brand. |
| `customerProfile.desktop.urlScheme` / `.siteUrl` | Agent Relay Desktop deep links: the URL scheme and site of the Desktop build for this deployment. Settings shows a "Connect your agents" link (`<urlScheme>://connect?site=<siteUrl>&…`). Needs a dashboard image from relay-webapp #88 or later. Not branding: on its own it changes nothing else. |

URLs may be `https`/`http`, same-origin paths or `data:image/…`. Example
customer values:

```yaml
relay-webapp:            # under the agent-relay umbrella; top level for this chart
  customerProfile:
    productName: Acme Relay
    logo:
      light: https://acme.example/brand/logo-on-light.svg
      dark: https://acme.example/brand/logo-on-dark.svg
    favicon: https://acme.example/brand/favicon.svg
    accentColor: "#7c3aed"
    brandColor: "#5b21b6"
    supportUrl: mailto:support@acme.example
    poweredByAgentRelay: true
```

The same JSON object is the customer profile for other Agent Relay clients.

```sh
helm lint --strict charts/relay-webapp \
  -f charts/relay-webapp/ci/default-values.yaml
```

## Session read API

`runtime.sessionReadApiEnabled: true` renders `DASHBOARD_SESSION_READ_API_ENABLED=true`, so the page reads session lists, search, activity, turns and events directly from the session read API with the access token Control hands it. It needs relay-webapp main `53e39ca9` or later, and the read API's `cors.allowedOrigins` must name this dashboard's origin.
