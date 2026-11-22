# Hardening the GKE edge

Three optional controls on the load balancer in front of the install. Do them
after step 14 of [0-START-HERE.md](0-START-HERE.md), in any order.

| Control | What it does | Default |
| --- | --- | --- |
| [TLS policy](#1-tls-policy) | Refuses TLS 1.0 and 1.1 | **On** when this release's Terraform (step 4) created your resources |
| [Cloud Armor](#2-cloud-armor) | OWASP rules, a sign-in rate limit, and optionally an allowlist of source addresses | Off |
| [A proxy in front (Cloudflare)](#3-cloudflare-in-front) | Only the proxy may reach the load balancer | Off |
| [Internal only (VPN)](#4-internal-only-behind-your-vpn) | No public address at all | Off |

**Which release.** Check before you start; the answer differs by control.

| Release | TLS policy, TLS Secret (sections 1, 3 item 1) | Internal mode (section 4) | Cloud Armor (sections 2, 3) |
| --- | --- | --- | --- |
| agent-relay-2026.11.16 and earlier (chart 0.7.54, the one 0-START-HERE.md pins) | No: the chart ignores the keys without an error, and the Terraform has no `edge_*` inputs | No | No |
| agent-relay-2026.11.18 (chart 0.7.63) | Yes | Yes | **No. Do not create the policy with this release's Terraform** |
| Later than agent-relay-2026.11.18 | Yes | Yes | Yes |

The Cloud Armor module in agent-relay-2026.11.18 writes regular expressions
that Google refuses (`Capture Groups are not allowed`), so
`terraform apply` fails on the sign-in rate limit and on every client rule,
and leaves a partial policy. It also lacks the check that keeps a caller who
holds the secret header from skipping the proxy. Both were fixed afterwards.
To tell which you have:

```sh
helm show chart "$CHART" | grep '^version'
grep -c max_advanced_rules infra/terraform/modules/gcp/edge-security/variables.tf   # 0: do not use it for Cloud Armor
```

If the second command prints 0 or the file is missing, set no
`edge_security_policy` and leave `gkeIngress.securityPolicy` empty until you
are on a later release. The TLS policy from that release is fine.

The chart and Terraform sides are covered by render and plan tests in this
repository. They have not yet been proven on a live GKE install; follow the
"Done when" checks below on yours.

## 1. TLS policy

Without an SSL policy a Google load balancer accepts TLS 1.0 and later.
`terraform/examples/gcp` creates the policy `<name>-tls` (profile `MODERN`,
TLS 1.2 minimum) and puts its name in `managed-values.json`
(`gkeIngress.sslPolicy`), so an install made with this release's step 4 and
step 11 has it already (step 4's plan then shows one resource more than the
count the guide states for the earlier release).

**An install made with an earlier release:** upgrade to this release's chart
and Terraform first, then run step 4's `terraform plan`/`apply` again (it
adds one resource), write `managed-values.json` again, and run step 11's
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

   Run `terraform plan` first and read `rule_counts` in the `edge` output:
   one policy holds at most 20 rules with an expression, and the plan tells
   you what this policy needs (the defaults need 3). Then `terraform apply`,
   and continue only if it finishes without an error. `terraform output edge`
   prints the policy's name (`<name>-edge`). This policy has the OWASP rules
   in **preview** (they log and do not block) and a limit of 60 sign-in
   requests a minute per client.

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

That list can be complete several minutes before every backend enforces the
policy (4 minutes when measured). If your policy refuses some requests (an
allowlist, Cloudflare, client rules), confirm with a request that it must
refuse, **on each backend**, before you rely on it. Each line below reaches a
different backend service:

```sh
IP=$(gcloud compute addresses describe $STATIC_IP_NAME --global --format='value(address)')
for url in "$DOMAIN/" "api.$DOMAIN/readyz" "cast.$DOMAIN/health" \
           "history.$DOMAIN/healthz" "history.$DOMAIN/v1/delivery/limits" "history.$DOMAIN/"; do
  h=${url%%/*}
  curl -sk -o /dev/null -w "$url %{http_code}\n" --resolve "$h:443:$IP" "https://$url"
done
```

The six are the dashboard, the API, Relaycast, the history reader, the
history upload service and the deny service. From an address the policy does
not admit, every line must end in `403`. Repeat until they all do. Warnings
that mention `Translate` in `kubectl describe ingress` while the policy
attaches are transient.

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
   `<client>, <Cloudflare>, <load balancer>` and the value is 3 (also
   measured). Check yours as below.

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

   **Raise the number only after item 3 is applied and the "Done when" below
   shows `direct 403`.** While the load balancer still answers requests that
   skip Cloudflare, a caller who connects to it directly can put any address
   in `X-Forwarded-For`, and with 3 the API would believe it.

5. **Which clients may reach which paths** (optional). To let a vendor's
   published ranges reach only the session upload paths, your own ranges
   reach everything, and nobody else anything, add `client_ip_rules` to the
   policy. Cloud Armor then decides by the client address Cloudflare reports
   (`CF-Connecting-IP`), which the secret header from item 3 makes
   trustworthy:

   ```hcl
   edge_security_policy = {
     create          = true
     cloudflare      = { enabled = true }
     connecting_asns = [13335]   # Cloudflare's network; see below
     rate_limits     = []
     client_ip_rules = [
       { name = "vendors", hosts = ["history.<domain>"], path_prefixes = ["/v1/delivery", "/v1/turns", "/v1/auth/token/refresh"], cidrs = ["<vendor range>", "<your range>"], rate_limit = { count = 600, interval_sec = 60 } },
       { name = "sign-in", path_prefixes = ["/login", "/api/v1/auth", "/cloud/api/v1/auth"], cidrs = ["<your range>"], rate_limit = { count = 60, interval_sec = 60 } },
       { name = "staff", path_prefixes = ["/"], cidrs = ["<your range>"], unthrottled = true },
     ]
   }
   ```

   `connecting_asns` matters here. A request that one of these rules admits
   is not checked against Cloudflare's address ranges afterwards, so without
   it anyone who learned the secret header could connect straight to the
   load balancer and claim to be any client. With it, a connection that does
   not come from Cloudflare's network is refused before any of these rules.
   Terraform refuses `client_ip_rules` without it.

   After applying it, wait until it is enforced before you rely on it: a new
   rule took almost 4 minutes to reach every backend when measured, and until
   then a direct request with the header was still admitted. Repeat the loop
   from section 2 from a machine that is not behind Cloudflare, adding the
   secret header **and** a client address your staff rule admits:

   ```sh
   -H "x-origin-auth: <value>" -H "CF-Connecting-IP: <an address in your range>"
   ```

   until all six lines end in `403`. Both headers matter: without the
   claimed address the client rules themselves answer 403, which would look
   like success while the bypass is still open.

   One gap this cannot close: another Cloudflare customer who learned your
   secret header could send requests through their own Cloudflare zone, which
   arrive from the same network. Keep the header value secret, rotate it if
   it may have leaked (item 3), and treat it like a password.

   The first rule that matches a request's path decides it: its listed
   clients are admitted, everyone else gets 403. The last rule closes every
   other path. A request that a rule admits is not checked by any later
   rule, so each rule carries its own `rate_limit` (per client), and the
   sign-in limit is a rule of its own ahead of the closing one. The module's
   README (`terraform/modules/gcp/edge-security`) explains the limits.

   **A long vendor list does not fit.** One Cloud Armor policy holds at most
   20 rules with an expression, and Google does not raise that limit. After
   the secret header, the two WAF rules and the sign-in and staff rules,
   about 13 are left: roughly 100 vendor ranges. Terraform refuses a plan
   that needs more and says how many it counted (`rule_counts` in the `edge`
   output shows the same). For a vendor that publishes more, there are two
   ways:

   - **An address group** (needs Cloud Armor Enterprise, which is billed and
     takes up to an hour to activate). The whole list then counts as one
     entry in one rule:

     ```sh
     gcloud compute project-info update --cloud-armor-tier CA_ENTERPRISE_PAYGO
     gcloud network-security address-groups create agent-relay-vendor-a --location global \
       --type IPv4 --capacity 600 --purpose CLOUD_ARMOR
     gcloud network-security address-groups add-items agent-relay-vendor-a --location global \
       --items <range>,<range>,...
     ```

     and in the rule, add `address_groups = ["agent-relay-vendor-a"]` and
     remove only that vendor's ranges from `cidrs`. Keep your own ranges
     there (`cidrs = ["<your range>"]`): the rule denies everyone it does not
     list, so without them your users' uploads would get 403. When the vendor changes its list, update the
     group with `add-items` and `remove-items`; Terraform is not involved.
   - **A Cloudflare WAF custom rule** for that vendor's list, keeping only
     your own ranges here. No extra Google cost.

   The project also has a limit of 20 such rules across all its policies
   (`SECURITY_POLICY_CEVAL_RULES`). That one can be raised, and a request was
   granted in seconds when measured. If another policy in the project already
   uses some, the apply fails part-way with
   `Quota 'SECURITY_POLICY_CEVAL_RULES' exceeded. Limit: 20.0 globally`.

   **If an apply fails, do not use the policy yet.** It then holds an
   arbitrary part of its rules, for example the rule that denies the sign-in
   paths without the rule that admits you. Fix the cause and run
   `terraform apply` again until it exits without an error. Only then set
   `gkeIngress.securityPolicy`.

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

## 4. Internal only, behind your VPN

Needs the `agent-relay` chart 0.7.60 or later (an earlier chart ignores
`gkeIngress.mode` and would create a public load balancer).

Instead of a public load balancer, the install can have a private address
that only your VPC and the networks routed to it (VPN, Interconnect) can
reach. Decide this before step 6 of the guide: the address, DNS and
certificate all differ. Agents and desktops that are not on the VPN cannot
connect or upload sessions.

1. **Network.** Use `terraform/modules/gcp/internal-edge` (its README has the
   call). It creates a proxy-only subnet (pick a free /23 in the VPC), a
   reserved private address, and the firewall rule that lets the load
   balancer's proxies reach the nodes. This replaces step 6's
   `gcloud compute addresses create ... --global`.

2. **DNS.** Create A records for `<domain>`, `api.<domain>`, `cast.<domain>`
   and `history.<domain>` pointing at the module's `address` output, in a zone
   your VPN clients resolve.

3. **Certificate.** Google cannot issue a managed certificate for a private
   address. Create a `kubernetes.io/tls` Secret for the four names (for
   example with cert-manager and a DNS-01 challenge, which needs no inbound
   access), or upload a regional certificate:

   ```sh
   gcloud compute ssl-certificates create agent-relay-internal --region $REGION \
     --certificate fullchain.pem --private-key privkey.pem
   ```

4. **Values.** Copy `values-gcp-internal.yaml` from the chart, replace
   `10.129.0.0/23` with your proxy-only range in all six places, set
   `staticIpName` and the certificate, then merge it into `values.yaml`:

   ```sh
   cp "$CHART/values-gcp-internal.yaml" internal.yaml
   # edit internal.yaml, then:
   yq -i '. *= load("internal.yaml")' values.yaml
   yq '.gkeIngress.mode, .gkeIngress.internal.proxyOnlySubnetCidr' values.yaml
   ```

   The last command prints `internal` and your range. The settings go into
   `values.yaml`, not a separate `-f` file, because every `helm upgrade` in
   this guide (steps 11, 13, 16, 17 and each later upgrade) reads
   `values.yaml`. Helm keeps nothing from the previous command: an upgrade
   without these settings would switch the install back to a public load
   balancer and drop the proxy-only range from the NetworkPolicies.

   The file also clears `gkeIngress.sslPolicy` and `securityPolicy`: GKE
   cannot apply them to an internal load balancer, so sections 1 and 2 above
   do not apply to this mode.

**Done when**, from a machine on the VPN:

```sh
kubectl -n $NAMESPACE get ingress agent-relay -o jsonpath='{.metadata.annotations.kubernetes\.io/ingress\.class} {.status.loadBalancer.ingress[0].ip}{"\n"}'
curl -fsS "https://api.$DOMAIN/readyz" && echo " api ok"
```

prints `gce-internal` with a private address, then `api ok`; and from a
machine that is **not** on the VPN the same `curl` cannot connect. Step 14's
other checks apply unchanged (skip the `managedcertificate` one).

- **Requests hang, then 504:** the firewall rule from the proxy-only subnet
  is missing, or a backend's `networkPolicy` does not list the range.
- **`Error syncing to GCP ... proxy-only subnetwork`** in
  `kubectl describe ingress`: the VPC has no active proxy-only subnet in the
  cluster's region.
- Sign-in rate limits: check `trustedProxies` as in section 3, item 4. The
  internal load balancer's `X-Forwarded-For` has not been measured.

## Removing these

**Cloud Armor.** Clearing `gkeIngress.securityPolicy` alone does not detach
the policy: GKE leaves a backend's policy in place when the field is absent,
and detaches only when it is set to an empty name. A policy that a backend
still uses cannot be deleted. So, in this order:

```sh
# 1. Detach from every backend, while the value is still set.
for bc in $(kubectl -n $NAMESPACE get backendconfig -o name); do
  kubectl -n $NAMESPACE patch "$bc" --type merge -p '{"spec":{"securityPolicy":{"name":""}}}'
done
# 2. Wait until no backend service uses it (prints 0; allow 10 minutes).
gcloud compute backend-services list --format='value(securityPolicy)' | grep -c agent-relay-edge
```

3. Clear `gkeIngress.securityPolicy` (and the dashboard's `backend-config`
   annotation) in `values.yaml` and run step 11's `helm upgrade`.
4. Set `edge_security_policy = { create = false }` and `terraform apply`.

**TLS policy.** The name reaches the chart from `managed-values.json`, which
only changes after a Terraform apply, and Terraform cannot delete a policy
that is still attached. So detach it through `values.yaml` first:

1. Add `sslPolicy: ""` under `gkeIngress:` in `values.yaml` (it is read after
   `managed-values.json`, so it wins) and run step 11's `helm upgrade`.
2. Wait until the load balancer no longer uses the policy:

   ```sh
   gcloud compute target-https-proxies list --format='table(name,sslPolicy.basename())'
   ```

   If the policy is still listed after 10 minutes, clear it on that proxy:
   `gcloud compute target-https-proxies update <proxy name> --clear-ssl-policy`.
3. Set `edge_ssl_policy = { create = false }`, run `terraform apply`, and
   write `managed-values.json` again (step 4). The line added in 1 can then
   be removed.

The load balancer goes back to Google's default policy, which accepts TLS 1.0.

The detach behaviour is from Google's documentation and has not been run on a
live install here.
