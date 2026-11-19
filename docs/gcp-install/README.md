# GCP customer setup

For an assisted installation, the customer has three tasks below. Agent Relay
prepares the configuration, installs the application and verifies it with the
approved operator. A customer running the application installation themselves
uses the [operator reference](0-START-HERE.md).

## 1. Confirm the inputs

Confirm the GCP project ID/number, region, GKE cluster/VPC, non-overlapping
network/VPN ranges, four hostnames (website, API, Relaycast, History), DNS owner,
TLS choice, first administrator and required labels. Agent Relay prepares the
Terraform inputs, Helm values and production Desktop identity for your review.
Private keys and origin-header values stay in your approved secret path.

**Cluster prerequisite:** the platform root uses existing GKE with Workload
Identity and enforced NetworkPolicies, and a VPC with Private Services Access.
If absent, the approved operator must provision them first. The
[foundation Terraform root](../../terraform/examples/gcp-foundation/README.md)
is still held/source only; the current [cluster setup procedure](0-START-HERE.md#starting-from-an-empty-project)
is manual. This guide does not claim a complete one-command installer.

## 2. Review and apply Terraform

Use the completed inputs and customer-approved state/backend. First apply
[gcp-vpn-network](../../terraform/examples/gcp-vpn-network/README.md) if a VPN
connector is needed, then pass its egress address into the
[gcp platform root](../../terraform/examples/gcp/README.md). Keep separate state.
The operator checks NAT/address ownership and enables the default-off VPN root
only in the reviewed inputs; it creates networking, not the VPN VM/software.

In each selected root:

```sh
terraform init
terraform plan -out=install.tfplan
# Review target, changes and costs; apply only the approved saved plan.
terraform apply install.tfplan
```

From the platform root, pass the non-secret output to the application operator:
`terraform output -json chart_values > managed-values.json`.

## 3. Configure DNS and hand over to the application operator

Point the four names at the reserved Ingress IP. For Cloudflare, configure
proxied DNS, Full (strict), Origin CA TLS and the origin header using the
[Cloudflare instructions](3-EDGE-HARDENING.md#3-cloudflare-in-front).

Agent Relay completes database bootstrap, Helm, first-admin setup, Desktop
builds/feed and application checks under the agreed access and release approvals.
The [edge preparer](EDGE-DESKTOP-CONFIG.md) keeps the URLs consistent. Keep MCP
connectors on the API host when that is the host in the vendor allowlist.

Handover requires sign-in, session upload, MCP, the agreed VPN/origin denials
and Desktop download/update checks. Terraform success alone is not acceptance.
Review [qualification limits](NOT-QUALIFIED.md) and the selected release's
evidence before production. [Detailed operator procedures](FILES.md), optional
features, upgrades and recovery are separate from these customer tasks.
