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

`runtime.analyticsEnabled` controls the compatible image's
`DASHBOARD_ANALYTICS_ENABLED` runtime flag. Its default `null` emits nothing and
preserves the image default; explicit `true` and `false` both render as strings.
Browser analytics use Control's collector proxy. Configure the Control adapter
and private collector separately; the dashboard receives no collector credential
or hosted exporter configuration from this value.

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

## Hosted logo (`global.branding.logo`)

The chart can host one customer logo on the dashboard origin, at
`<dashboard origin>/brand/<file>`, so the sign-in page and the dashboard can
show it without another web server or ingress route. Under the agent-relay
umbrella the same value also points relay-control's `SELFHOST_LOGIN_LOGO_URL`
at it (see the relay-control README).

| key | meaning |
| --- | --- |
| `global.branding.logo.svg` | Inline SVG markup, at most 256 KiB. The chart creates `<fullname>-brand` and serves it as `/brand/logo.svg`. Markup with `<script`, `on…=` event handlers, `javascript:` (also with whitespace inside), `<foreignObject`, character references (`&#…;`) or a `<!DOCTYPE`/`<!ENTITY` declaration is refused. |
| `global.branding.logo.existingConfigMap` | A ConfigMap you create in the release namespace holding a PNG (`binaryData`, e.g. `kubectl create configmap relay-brand --from-file=logo.png`). Its content is not linted, so SVG is refused here: put an SVG in `svg`. |
| `global.branding.logo.key` | The key in `existingConfigMap`, which is also the served file name: `[A-Za-z0-9._-]`, ending in `.png`. Default `logo.png`. |

Set `svg` or `existingConfigMap`, not both. The file is mounted read-only at
`/usr/share/nginx/html/brand`; ConfigMap edits reach the pod without a
restart (after the kubelet sync). Images from relay-webapp
[#132](https://github.com/AgentWorkforce/relay-webapp/pull/132) or later serve
`/brand/` with `Content-Security-Policy: default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox`,
`X-Content-Type-Options: nosniff` and `Cache-Control: public, max-age=300`,
and return 404 for a missing file. Older images serve it through the app
route (`nosniff`, `Cache-Control: no-cache`, no CSP, and the app shell for a
missing file), which is why inline SVG is checked. To use the logo as the
dashboard's own mark too, set `customerProfile.logo: /brand/logo.svg`.

```yaml
global:
  branding:
    logo:
      svg: |
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 32">...</svg>
```

## Session read API

`runtime.sessionReadApiEnabled: true` renders `DASHBOARD_SESSION_READ_API_ENABLED=true`, so the page reads session lists, search, activity, turns and events directly from the session read API with the access token Control hands it. It needs relay-webapp main `53e39ca9` or later, and the read API's `cors.allowedOrigins` must name this dashboard's origin.

`runtime.coordinationOverlapsEnabled` is a strict boolean and defaults to
`false`, so the coordination-overlaps view remains hidden even when the backend
endpoint is available. Setting it to `true` renders
`DASHBOARD_COORDINATION_OVERLAPS_ENABLED=true`. It requires a dashboard image
containing relay-webapp #124 and also requires `runtime.sessionReadApiEnabled`
plus a read API serving the Postgres coordination-overlaps contract. Pin and
verify that image before enabling the view; the chart refuses the view flag
without the direct-read flag, and older images ignore the setting.
