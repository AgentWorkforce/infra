# Hardening the GKE edge

Three optional controls on the load balancer in front of the install. Do them
after step 14 of [0-START-HERE.md](0-START-HERE.md), in any order.

| Control | What it does | Default |
| --- | --- | --- |
| [TLS policy](#1-tls-policy) | Refuses TLS 1.0 and 1.1 | **On** when Terraform (step 4) created your resources |
| [Cloud Armor](#2-cloud-armor) | OWASP rules, a sign-in rate limit, and optionally an allowlist of source addresses | Off |
| [A proxy in front (Cloudflare)](#3-cloudflare-in-front) | Only the proxy may reach the load balancer | Off |

The chart and Terraform sides are covered by render and plan tests in this
repository. They have not yet been proven on a live GKE install; follow the
"Done when" checks below on yours.

## 1. TLS policy

Without an SSL policy a Google load balancer accepts TLS 1.0 and later.
`terraform/examples/gcp` creates the policy `<name>-tls` (profile `MODERN`,
TLS 1.2 minimum) and puts its name in `managed-values.json`
(`gkeIngress.sslPolicy`), so an install that follows step 4 and step 11 has it
already.

**An existing install:** run step 4's `terraform plan`/`apply` again (it adds
one resource), write `managed-values.json` again, and run step 11's
`helm upgrade`.

**Brought your own resources?** Create the policy and name it in `values.yaml`:

```sh
gcloud compute ssl-policies create agent-relay-tls --profile MODERN --min-tls-version 1.2 --global
```

```yaml
gkeIngress:
  sslPolicy: agent-relay-tls
```

**Done when** (allow 5 minutes after the upgrade):

```sh
kubectl -n $NAMESPACE get frontendconfig agent-relay -o jsonpath='{.spec.sslPolicy}{"\n"}'
openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -tls1_1 </dev/null 2>&1 | grep -c 'Cipher is (NONE)\|alert protocol version\|no protocols available'
openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -tls1_2 </dev/null 2>/dev/null | grep 'Protocol'
```

The first prints the policy name, the second a number above 0 (TLS 1.1 is
refused), the third `TLSv1.2`.

- **`Error syncing to GCP ... sslPolicies/... was not found`** in
  `kubectl -n $NAMESPACE describe ingress agent-relay`: the policy does not
  exist in the cluster's project. The load balancer keeps its previous
  settings until it does.
- **Stricter ciphers:** `edge_ssl_policy = { profile = "RESTRICTED" }` in
  `terraform.tfvars`. Check the desktop app and your CLIs connect before you
  roll it out.
- **Opt out:** `edge_ssl_policy = { create = false }`.

## 2. Cloud Armor

The policy applies to every backend behind the load balancer: the dashboard,
the API, Relaycast, both history services, and Relayfile and durable actors
when you run them.

1. Create the policy. In `infra/terraform/examples/gcp/terraform.tfvars`:

   ```hcl
   edge_security_policy = { create = true }
   ```

   Run `terraform apply`. `terraform output edge` prints its name
   (`<name>-edge`). This policy has the OWASP rules in **preview** (they log
   and do not block) and a limit of 60 sign-in requests a minute per client.

2. Name it in `values.yaml`, and bind the dashboard Service to its
   BackendConfig (`<gkeIngress.name>-dashboard`):

   ```yaml
   gkeIngress:
     securityPolicy: agent-relay-edge
   relay-webapp:
     service:
       annotations:
         cloud.google.com/neg: '{"ingress": true}'
         cloud.google.com/backend-config: '{"default": "agent-relay-dashboard"}'
   ```

   Run step 11's `helm upgrade`. If an annotation is missing, the upgrade
   stops and prints the value to set.

**Done when** (allow 10 minutes):

```sh
kubectl -n $NAMESPACE get backendconfig -o custom-columns=NAME:.metadata.name,POLICY:.spec.securityPolicy.name
gcloud compute backend-services list --format='table(name,securityPolicy.basename())' | grep -c agent-relay-edge
```

Every BackendConfig shows the policy, and the count equals the number of
backend services of the Ingress (6 for the default install).

**Turn the OWASP rules on.** Session transcripts and messages contain code,
SQL and shell text, which is what those rules look for. Use the install
normally for a week, then look for requests the rules would have blocked:

```sh
gcloud logging read 'resource.type="http_load_balancer" AND jsonPayload.previewSecurityPolicy.outcome="DENY"' \
  --freshness 7d --limit 50 --format='table(httpRequest.requestUrl,jsonPayload.previewSecurityPolicy.preconfiguredExprIds)'
```

When it prints nothing you care about, set
`edge_security_policy = { create = true, waf = { preview = false } }` and
apply. To drop a rule that only matches your own traffic, list the ones you
keep in `waf.rules` (`terraform/modules/gcp/edge-security`).

**Only some source addresses** (for example your VPN's egress range):

```hcl
edge_security_policy = { create = true, source_ip_allowlist = ["198.51.100.0/24"] }
```

Everything else gets 403. The desktop app, CLIs and any agent that uploads
sessions must come from those addresses too.

## 3. Cloudflare in front

With Cloudflare proxying the four names, lock the load balancer so that only
Cloudflare can reach it.

1. **Certificate.** Google cannot issue the managed certificate while the
   names resolve to Cloudflare. Serve a certificate from a Secret instead, for
   example a [Cloudflare Origin CA](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)
   certificate that covers all four names:

   ```sh
   kubectl -n $NAMESPACE create secret tls agent-relay-origin-tls --cert origin.pem --key origin.key
   ```

   ```yaml
   gkeIngress:
     tlsSecretName: agent-relay-origin-tls
   ```

   Step 14's `managedcertificate` check no longer applies. Renew the Secret
   before the certificate expires; nothing renews it for you. In Cloudflare
   set the zone's SSL mode to **Full (strict)**.

2. **Names.** The install uses `<domain>`, `api.<domain>`, `cast.<domain>` and
   `history.<domain>`. Cloudflare's free Universal certificate covers a zone's
   apex and one level below it. If `<domain>` is itself a subdomain
   (`ar.example.com`, so `api.ar.example.com`), order an Advanced certificate
   for the four names or turn on Total TLS.

3. **Policy.** In `terraform.tfvars`:

   ```hcl
   edge_security_policy      = { create = true, cloudflare = { enabled = true } }
   edge_origin_secret_header = { name = "x-origin-auth", values = ["<openssl rand -hex 32>"] }
   ```

   In Cloudflare, add a **request header transform rule** for the four names
   that sets `x-origin-auth` to the same value. Apply Terraform, then set
   `gkeIngress.securityPolicy` as in section 2. Cloudflare's addresses are
   shared by all its customers; the header is what proves a request came
   through your zone. Its value is in the Terraform state and in the Cloud
   Armor policy, so keep the state private. **To rotate it:** put the new
   value second in `values` and apply, change the Cloudflare rule to the new
   value, then remove the old value and apply. Requests keep flowing
   throughout.

4. **Client addresses.** relay-control finds the client's address by
   counting `relay-control.auth.trustedProxies` entries from the right of the
   `X-Forwarded-For` header. The Google load balancer appends two entries:
   the address it received the request from, and its own. Measured on a live
   GKE install, the header is `<client>, <load balancer>` and the right value
   is 2. Cloudflare adds one more, so behind Cloudflare the header is
   `<client>, <Cloudflare>, <load balancer>` and the value is 3. The
   Cloudflare case is expected, not yet measured; check it as below.

   ```yaml
   relay-control:
     auth:
       trustedProxies: 3   # Cloudflare, then the Google load balancer's two entries
   ```

   To check: load the dashboard from a network whose public address you know
   (`curl -s https://ifconfig.me`), then read the header the pods received:

   ```sh
   kubectl -n $NAMESPACE logs deploy/relay-webapp -c dashboard --tail 5
   ```

   The last quoted field of each line is `X-Forwarded-For`. Count from the
   right to your address: that count is `trustedProxies`. A number that is
   too low makes every user share one sign-in limit and lockout; a number
   that is too high lets a client forge its address.

5. **Which clients may reach which paths** (optional). To let a vendor's
   published ranges reach only the session upload paths, your own ranges
   reach everything, and nobody else anything, add `client_ip_rules` to the
   policy. Cloud Armor then decides by the client address Cloudflare reports
   (`CF-Connecting-IP`), which the secret header from item 3 makes
   trustworthy:

   ```hcl
   edge_security_policy = {
     create     = true
     cloudflare = { enabled = true }
     client_ip_rules = [
       { name = "vendors", hosts = ["history.<domain>"], path_prefixes = ["/v1/delivery", "/v1/turns", "/v1/auth/token/refresh"], cidrs = ["<vendor range>", "<your range>"] },
       { name = "staff", path_prefixes = ["/"], cidrs = ["<your range>"] },
     ]
   }
   ```

   Rules apply in order; the last one closes every other path. The module's
   README (`terraform/modules/gcp/edge-security`) explains the limits. A
   vendor that publishes hundreds of ranges needs a higher Cloud Armor quota,
   or that list enforced as a Cloudflare WAF custom rule instead.

**Done when:**

```sh
curl -s -o /dev/null -w "through Cloudflare %{http_code}\n" "https://api.$DOMAIN/readyz"
curl -sk -o /dev/null -w "direct %{http_code}\n" --resolve "api.$DOMAIN:443:$(gcloud compute addresses describe $STATIC_IP_NAME --global --format='value(address)')" "https://api.$DOMAIN/readyz"
```

`through Cloudflare 200` and `direct 403`, and the count in item 4 matches
`trustedProxies`.

- **Long-lived connections.** The desktop app, Relaycast and the flows worker
  queue hold WebSocket and event-stream connections open. Cloudflare proxies
  WebSockets by default and closes a connection that carries no data for 100
  seconds; the services send keep-alives more often than that, but this path
  has not been proven end to end.
- **Upload size.** Cloudflare limits a request body to 100 MB on its Free and
  Pro plans.
- **Labels.** The Cloud Armor policy carries your `labels`. SSL policies, and
  the forwarding rules and backend services that GKE creates for the Ingress,
  have no labels in Google's API. For cost reports use
  [GKE cost allocation](https://cloud.google.com/kubernetes-engine/docs/how-to/cost-allocations),
  which covers what runs in the cluster.
- **Cloudflare changes its ranges** rarely and announces it. Before each
  `terraform apply`, compare <https://www.cloudflare.com/ips/> with
  `cloudflare.ipv4_cidrs` in the module (the list there is dated).

## Removing these

`terraform destroy` (or setting `create = false`) removes the policies. Clear
`gkeIngress.sslPolicy` and `gkeIngress.securityPolicy` and run `helm upgrade`
first: a policy that a load balancer still uses cannot be deleted.
