# gcp/internal-edge

Network prerequisites for the `agent-relay` chart's internal-only GKE edge (`gkeIngress.mode: internal`): a regional internal Application Load Balancer that GKE creates from the Ingress. The install then has a private address and is reachable only from the VPC and the networks routed to it (VPN, Interconnect).

| Resource | Why | Chart value |
| --- | --- | --- |
| Proxy-only subnet `<name>-proxy-only` (`REGIONAL_MANAGED_PROXY`) | The load balancer's Envoy proxies take their addresses from it. A VPC has one active proxy-only subnet per region; set `proxy_only_subnet.create = false` to use an existing one | `gkeIngress.internal.proxyOnlySubnetCidr`, and every backend's `networkPolicy` |
| Regional internal address `<name>-internal` | The load balancer's stable private address; DNS points at it | `gkeIngress.staticIpName` |
| Firewall rule `<name>-allow-proxy-only` | GKE opens the firewall for Google's health checks but not for the proxy-only subnet. The rule admits only that subnet, only to instances running as the node service account, only on the backend ports | none |

This module opens no path from outside the VPC and creates no external address. Reaching the address from offices or laptops is your VPN's or Interconnect's routing, plus DNS records for the install's hosts in a zone those clients resolve.

**Not created here:** the certificate. A Google-managed certificate cannot be used on an internal load balancer. Use a `kubernetes.io/tls` Secret (`gkeIngress.tlsSecretName`), for example issued by cert-manager with a DNS-01 challenge, or a regional self-managed certificate (`gcloud compute ssl-certificates create NAME --region REGION --certificate ... --private-key ...`, then `gkeIngress.internal.preSharedCerts`). A Terraform-managed certificate would put the private key in state.

`labels` reach the address. Subnets and firewall rules have no labels in the API.

```hcl
module "internal_edge" {
  source = "../../modules/gcp/internal-edge"

  project_id           = var.project_id
  region               = var.region
  name                 = "agent-relay"
  network              = module.foundation.network.id
  subnetwork           = module.foundation.network.subnet_self_link
  node_service_account = module.foundation.gke.node_service_account
  proxy_only_subnet    = { cidr = "10.129.0.0/23" }
}
```

Tested with a mock provider only; not yet applied to a live project.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6 |
| google | >= 7.0, < 8.0 |

### Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 8.0 |

### Resources

| Name | Type |
| ---- | ---- |
| [google_compute_address.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_address) | resource |
| [google_compute_firewall.proxy_only](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_subnetwork.proxy_only](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name | Name prefix: the address is <name>-internal, the proxy-only subnet <name>-proxy-only and the firewall rule <name>-allow-proxy-only. | `string` | n/a | yes |
| network | Self link or ID of the cluster's VPC network. | `string` | n/a | yes |
| node\_service\_account | Email of the service account the GKE nodes run as. The firewall rule lets the proxy-only subnet reach only instances running as it. | `string` | n/a | yes |
| project\_id | Project of the GKE cluster and its VPC. | `string` | n/a | yes |
| proxy\_only\_subnet | The VPC's proxy-only subnet for regional Envoy load balancers in this region. A VPC has one active proxy-only subnet per region: create = true makes it (cidr is a free RFC 1918 range, /26 or larger, /23 recommended); create = false uses one that already exists, and cidr is its range. | ```object({ create = optional(bool, true) cidr = string })``` | n/a | yes |
| region | Region of the GKE cluster. The internal load balancer, its address and the proxy-only subnet are regional. | `string` | n/a | yes |
| subnetwork | Self link or ID of the subnet the load balancer's address is taken from, normally the cluster's node subnet. | `string` | n/a | yes |
| address | A specific unused address in subnetwork for the load balancer (null: Google picks one). DNS for every install host points at it. | `string` | `null` | no |
| backend\_ports | TCP ports of the pods behind the Ingress, which the load balancer's proxies connect to: 3000 (control API), 8080 (dashboard, session read API, Relayfile, relaygate), 8081 (session ingest), 8787 (Relaycast) and 7100 (durable actors). Change it if you changed a server port in the values. | `list(string)` | ```[ "3000", "7100", "8080", "8081", "8787" ]``` | no |
| labels | Labels for the reserved address (the only resource here that takes labels). managed-by=terraform is always added. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| address | The load balancer's private address. Point the DNS records of every install host at it, in a zone your VPN clients resolve. |
| chart\_values | The gkeIngress keys for internal mode. Add the certificate (gkeIngress.tlsSecretName or internal.preSharedCerts) and the NetworkPolicy lists from values-gcp-internal.yaml. |
| proxy\_only\_subnet\_cidr | Chart value gkeIngress.internal.proxyOnlySubnetCidr, and the range to add to every backend's networkPolicy (values-gcp-internal.yaml). |
| static\_ip\_name | Chart value gkeIngress.staticIpName. |
<!-- END_TF_DOCS -->
