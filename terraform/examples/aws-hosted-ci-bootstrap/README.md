# Hosted pipeline CI bootstrap

infra-expert executes this root through the existing protected bootstrap CI identity. Its own encrypted, locked S3 backend must already exist separately from the bucket this root creates. Supply private backend settings including the expected bucket owner and use_lockfile=true. Verify the CI identity, account, backend and GitHub subject template before planning. The default looks up the existing GitHub issuer. Select create_oidc only after account inventory confirms absence.

Provision the workload backend with the bucket, state key and KMS key from this root, encrypt=true and use_lockfile=true. Supply the CI module settings only inside the protected workflow. Use a protected apply environment with deployment restricted to main. Review the saved workload plan before import/apply. IAM limits the workload update to one event source mapping. The plan gate must additionally enforce the approved concurrency change.

For the private parameter, support-fixer and envs-lead-3 assemble and validate one JSON object in the private channel. Supply it to the protected bootstrap job as ephemeral TF_VAR_private_tfvars on both plan and apply, pinned to the same immutable secret version. Set tfvars_version to a new positive integer on each revision. Disable shell tracing and Terraform debug logging. Only SecureString metadata and its numeric revision enter state. Do not archive the input or send it on Relay. An SSM advanced parameter has an 8 KiB limit; verify the byte length privately before execution.

The first live plan depends on an authorized bootstrap CI identity, a separate backend and verified private inputs. Initializing this root with -backend=false and running terraform validate checks provider schemas offline.
