locals {
  # Fixed buildspec. The caller (a GitHub job) passes only data: the bundle key and digest, the run id and, for
  # the apply project, MODE apply or rollback. The bundle holds scripts/selfhost/ci-deploy.sh, the chart and the
  # environment's values; plan bundles come only from the plan_subjects refs, apply bundles only from the
  # approval environment.
  buildspec = <<-EOT
    version: 0.2
    env:
      shell: bash
    phases:
      install:
        commands:
          - set -euo pipefail
          - mkdir -p "$HOME/bin" && export PATH="$HOME/bin:$PATH"
          - curl -fsSL -o /tmp/helm.tgz "https://get.helm.sh/helm-$${HELM_VERSION}-linux-amd64.tar.gz"
          - echo "$${HELM_SHA256}  /tmp/helm.tgz" | sha256sum -c -
          - tar -xzf /tmp/helm.tgz -C /tmp && install -m 0755 /tmp/linux-amd64/helm "$HOME/bin/helm"
          - curl -fsSL -o "$HOME/bin/kubectl" "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
          - echo "$${KUBECTL_SHA256}  $HOME/bin/kubectl" | sha256sum -c - && chmod 0755 "$HOME/bin/kubectl"
          - python3 -m pip install --quiet "pyyaml==6.0.2"
          - if [ "$${CI_DEPLOY_PROJECT_MODE}" = apply ]; then dnf install -y -q postgresql17 >/dev/null; fi
      build:
        commands:
          - set -euo pipefail
          - export PATH="$HOME/bin:$PATH"
          - '[[ "$${RUN_ID:-}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "RUN_ID is required"; exit 2; }'
          - '[[ "$${BUNDLE_KEY:-}" = "$${CI_DEPLOY_BUNDLE_PREFIX}"* ]] || { echo "BUNDLE_KEY must be under $${CI_DEPLOY_BUNDLE_PREFIX}"; exit 2; }'
          - aws s3 cp --only-show-errors "s3://$${CI_DEPLOY_BUCKET}/$${BUNDLE_KEY}" /tmp/bundle.tgz
          - echo "$${BUNDLE_SHA256}  /tmp/bundle.tgz" | sha256sum -c -
          - mkdir -p /tmp/b && tar -xzf /tmp/bundle.tgz -C /tmp/b
          - export KUBECONFIG=/tmp/kubeconfig && aws eks update-kubeconfig --name "$${CI_DEPLOY_CLUSTER}" --kubeconfig "$KUBECONFIG" >/dev/null
          - mode="$${CI_DEPLOY_PROJECT_MODE}"; if [ "$mode" = apply ]; then mode="$${MODE:-apply}"; fi
          - REPORT_DIR=/tmp/report bash /tmp/b/infra/scripts/selfhost/ci-deploy.sh "$mode" /tmp/b
      post_build:
        commands:
          - if [ -d /tmp/report ]; then aws s3 cp --only-show-errors --recursive /tmp/report "s3://$${CI_DEPLOY_BUCKET}/runs/$${RUN_ID}/$${CI_DEPLOY_PROJECT_MODE}/"; fi
  EOT

  tool_versions = {
    HELM_VERSION    = "v3.22.0"
    HELM_SHA256     = "1e4ab49e429626cf6c6958d914248b78c9730803c2751b87627e171dc800e7bb"
    KUBECTL_VERSION = "v1.35.10"
    KUBECTL_SHA256  = "c49a28f1f4efc4d475ed05f47f2ce8e563bf7bef69ed77fe1b924ea6d83b6327"
  }
}

resource "aws_codebuild_project" "this" {
  #checkov:skip=CKV_AWS_316:Privileged mode is off (the default); checkov reads the unset flag as unknown.
  for_each       = local.modes
  name           = "${var.name}-${each.key}"
  description    = "Agent Relay ${each.key} for ${var.cluster_name}; started only by GitHub OIDC (${each.key == "plan" ? "plan refs" : "environment ${var.apply_environment}"})."
  service_role   = aws_iam_role.build[each.key].arn
  build_timeout  = var.build_timeout_minutes
  queued_timeout = 30
  encryption_key = var.kms_key_arn

  # One build at a time per project: two applies never race.
  concurrent_build_limit = 1

  source {
    type      = "NO_SOURCE"
    buildspec = local.buildspec
  }
  artifacts {
    type = "NO_ARTIFACTS"
  }
  environment {
    type            = "LINUX_CONTAINER"
    image           = var.build_image
    compute_type    = var.compute_type
    privileged_mode = false
    dynamic "environment_variable" {
      for_each = merge(local.tool_versions, {
        CI_DEPLOY_PROJECT_MODE        = each.key
        CI_DEPLOY_BUCKET              = module.artifacts.bucket_name
        CI_DEPLOY_CLUSTER             = var.cluster_name
        CI_DEPLOY_NAME                = var.name
        CI_DEPLOY_BUNDLE_PREFIX       = each.value.bundle_prefix
        AWS_DEFAULT_REGION            = local.region
        PIP_DISABLE_PIP_VERSION_CHECK = "1"
      })
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }
  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.subnet_ids
    security_group_ids = [aws_security_group.builds.id]
  }
  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.builds.name
      stream_name = each.key
    }
  }
  tags = local.tags
}
