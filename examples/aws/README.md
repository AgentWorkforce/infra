# AWS (EKS) install example

A filled-in example of what [Install on EKS](https://agentrelay.com/docs/self-hosting/install-eks)
produces for release `agent-relay-2026.11.16` (chart 0.7.54), with the database on
RDS (Terraform-created or [existing/shared](https://agentrelay.com/docs/self-hosting/existing-rds)).
Use it to check the shape of your own files. **Every value here is an example.**

| File | Kubernetes object | Source of the real values |
|---|---|---|
| `values.yaml` | Helm values, applied after `charts/agent-relay/values-eks.yaml` and `values-eks-native.yaml` | Step 9 fills the published template |
| `secrets/01-agent-relay-secrets.yaml` | Secret `agent-relay-secrets` | Database URLs: `rds-setup.sh pre`. Keys: step 10 |
| `secrets/02-agent-relay-read-api.yaml` | Secret `agent-relay-read-api` | `rds-setup.sh pre` |
| `secrets/03-agent-relay-ingest-edge-runtime.yaml` | Secret `agent-relay-ingest-edge-runtime` | `rds-setup.sh pre`; `introspect-secret` copied in step 10 |
| `secrets/04-search-indexer-runtime.yaml` | Secret `search-indexer-runtime` | `rds-setup.sh pre` |
| `secrets/05-search-indexer-owner.yaml` | Secret `search-indexer-owner` | `rds-setup.sh pre` (fresh dedicated-owner installs) |
| `secrets/06-agent-relay-llm.optional.yaml` | Secret `agent-relay-llm` (optional) | Your model endpoint, see after-install |

The secret values are fake. Don't hand-write real ones: `rds-setup.sh` and step 10
generate them under `~/.agent-relay-install/secret-files/<Secret>/<key>` and create
the Secrets from those files. If you can't run shell scripts, do the same
setup by hand with [RDS database setup without rds-setup.sh](../../docs/self-hosted-rds-manual-setup.md)
(added in #470). Existing administrator-owned installs use the temporary
`hoopdb-admin-jobs` Secret only while migration/bootstrap Jobs run; it is not
represented by a committed example. To keep inputs in SOPS or SSM instead, see
[Secrets](https://agentrelay.com/docs/self-hosting/secrets). Never commit real values.

Check the example renders against the release:

```sh
git checkout agent-relay-2026.11.16
helm dependency build charts/sessions-pipeline && helm dependency build charts/agent-relay
helm template agent-relay charts/agent-relay -n agent-relay \
  -f charts/agent-relay/values-eks.yaml -f charts/agent-relay/values-eks-native.yaml \
  -f examples/aws/values.yaml >/dev/null && echo "render ok"
```
