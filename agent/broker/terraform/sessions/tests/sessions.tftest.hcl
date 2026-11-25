# Plan-only, mocked provider: no AWS credentials, no state, no apply.
mock_provider "aws" {
  override_data {
    target = data.aws_lambda_functions.all
    values = {
      function_names = ["some-other-function", "96bulls-aws-sessions-prod-session-pipeline"]
    }
  }
  override_data {
    target = data.aws_cloudwatch_log_group.this
    values = {
      name = "/aws/lambda/96bulls-aws-sessions-prod-session-pipeline"
    }
  }
}

# Placeholder ids: the real account id lives only in allowlist.json, and the run
# that pairs this root with the allowlist reads it from there.
variables {
  sessions_account_id = "111111111111"
  broker_role_arn     = "arn:aws:iam::222222222222:role/agent-cred-broker"
}

run "trusts_only_the_broker_with_its_tags_and_source_identity" {
  command = plan
  assert {
    condition     = length(output.trust_policy.Statement) == 3 && alltrue([for s in output.trust_policy.Statement : s.Principal.AWS == var.broker_role_arn && s.Effect == "Allow"])
    error_message = "every trust statement names only the broker role"
  }
  assert {
    condition     = output.trust_policy.Statement[0].Condition.Null == { "aws:RequestTag/agent-run" = "false", "aws:RequestTag/agent-ns" = "false", "aws:RequestTag/agent" = "false", "sts:SourceIdentity" = "false" }
    error_message = "AssumeRole requires the broker's tags and a source identity"
  }
  assert {
    condition     = output.trust_policy.Statement[1].Condition["ForAllValues:StringEquals"]["aws:TagKeys"] == ["broker-request-id", "agent-run", "agent-ns", "agent"]
    error_message = "only the broker's session tag keys"
  }
  assert {
    condition     = aws_iam_role.read.max_session_duration == 3600
    error_message = "1 h cap"
  }
}

run "trust_matches_the_other_broker_target_roles" {
  command = plan
  # The same three statements as the elevated role's trust: a reviewer can diff them.
  assert {
    condition     = [for s in output.trust_policy.Statement : s.Sid] == ["BrokerAssumesWithRequestTags", "BrokerTagsSessions", "BrokerSetsSourceIdentity"]
    error_message = "same trust statements as modules/elevated-role"
  }
  assert {
    condition     = strcontains(file("${path.module}/../modules/elevated-role/main.tf"), "Sid       = \"BrokerAssumesWithRequestTags\"") && strcontains(file("${path.module}/../modules/elevated-role/main.tf"), "\"aws:RequestTag/broker-request-id\" = \"cb-*\"")
    error_message = "the elevated role still has the trust this mirrors"
  }
}

run "permissions_are_the_function_configuration_and_its_one_log_group" {
  command = plan
  assert {
    condition     = length(output.permissions_policy.Statement) == 2 && alltrue([for s in output.permissions_policy.Statement : s.Effect == "Allow"])
    error_message = "two allows, nothing else"
  }
  assert {
    condition     = output.permissions_policy.Statement[0].Action == ["lambda:GetFunctionConfiguration", "lambda:ListVersionsByFunction", "lambda:ListAliases"]
    error_message = "Lambda: configuration, versions and aliases only"
  }
  assert {
    condition = output.permissions_policy.Statement[0].Resource == [
      "arn:aws:lambda:us-east-1:${var.sessions_account_id}:function:96bulls-aws-sessions-prod-session-pipeline",
      "arn:aws:lambda:us-east-1:${var.sessions_account_id}:function:96bulls-aws-sessions-prod-session-pipeline:*",
    ] && output.function_arn == output.permissions_policy.Statement[0].Resource[0]
    error_message = "that function and its versions and aliases, in this account and region"
  }
  assert {
    condition     = output.permissions_policy.Statement[1].Action == ["logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents"]
    error_message = "Logs: list and read streams only"
  }
  assert {
    condition = output.permissions_policy.Statement[1].Resource == [
      "arn:aws:logs:us-east-1:${var.sessions_account_id}:log-group:/aws/lambda/96bulls-aws-sessions-prod-session-pipeline",
      "arn:aws:logs:us-east-1:${var.sessions_account_id}:log-group:/aws/lambda/96bulls-aws-sessions-prod-session-pipeline:*",
    ] && output.log_group_arn == output.permissions_policy.Statement[1].Resource[0]
    error_message = "that log group and its streams, in this account and region"
  }
  assert {
    condition     = aws_iam_role_policy.read.policy == jsonencode(output.permissions_policy)
    error_message = "the role's inline policy is exactly the reviewed one"
  }
}

run "no_wildcard_action_no_code_download_no_write" {
  command = plan
  assert {
    condition     = alltrue(flatten([for s in output.permissions_policy.Statement : [for a in s.Action : !strcontains(a, "*")]]))
    error_message = "no wildcard in any action"
  }
  assert {
    # Every resource is one of the two named ARNs, alone or with ":*" (its versions/aliases or its streams).
    condition     = alltrue(flatten([for s in output.permissions_policy.Statement : [for r in s.Resource : contains([output.function_arn, "${output.function_arn}:*", output.log_group_arn, "${output.log_group_arn}:*"], r)]]))
    error_message = "no resource beyond the function and the log group"
  }
  assert {
    condition     = alltrue(flatten([for s in output.permissions_policy.Statement : [for a in s.Action : can(regex("^(lambda:(GetFunctionConfiguration|List[A-Za-z]+)|logs:(Describe|Get|Filter)[A-Za-z]+)$", a))]]))
    error_message = "read verbs only"
  }
  assert {
    condition     = !strcontains(jsonencode(output.permissions_policy), "lambda:GetFunction\"") && !strcontains(jsonencode(output.permissions_policy), "Invoke") && !strcontains(jsonencode(output.permissions_policy), "logs:StartQuery")
    error_message = "no code download link, no invoke, no Logs Insights"
  }
  assert {
    condition     = !strcontains(file("${path.module}/main.tf"), "data \"aws_lambda_function\" ")
    error_message = "the function's environment values never enter this root's state"
  }
}

run "matches_the_broker_allowlist" {
  command = plan
  variables {
    sessions_account_id = one([for k, a in jsondecode(file("../../allowlist.json")).accounts : k if a.label == "sessions-prod"])
  }
  assert {
    condition     = "arn:aws:iam::${var.sessions_account_id}:role/${output.role_name}" == jsondecode(file("${path.module}/../../allowlist.json")).accounts[var.sessions_account_id].roles.elevated
    error_message = "the allowlist's role for the sessions account is the one this creates"
  }
  assert {
    condition     = jsondecode(file("${path.module}/../../allowlist.json")).accounts[var.sessions_account_id].regions == [var.region]
    error_message = "the allowlist's one region is the function's"
  }
  assert {
    condition     = jsondecode(file("${path.module}/../../allowlist.json")).accounts[var.sessions_account_id].tier == "prod" && keys(jsondecode(file("${path.module}/../../allowlist.json")).accounts[var.sessions_account_id].roles) == ["elevated"]
    error_message = "prod tier with only an elevated role: every request goes to the approver"
  }
  assert {
    condition = alltrue([
      for c in jsondecode(file("${path.module}/../../allowlist.json")).workspaceAuto.capabilities :
      !contains(c.accounts, var.sessions_account_id)
    ])
    error_message = "no workspaceAuto capability in the sessions account: nothing is issued without approval"
  }
  assert {
    condition = alltrue([
      for d in try(jsondecode(file("${path.module}/../../allowlist.json")).delegatedApprovers, []) :
      alltrue([for c in d.capabilities : !contains(c.accounts, var.sessions_account_id)])
    ])
    error_message = "no delegated approver has a capability in the sessions account"
  }
}

run "refuses_when_the_function_does_not_exist" {
  command = plan
  override_data {
    target = data.aws_lambda_functions.all
    values = {
      function_names = ["some-other-function"]
    }
  }
  expect_failures = [data.aws_lambda_functions.all]
}

run "rejects_wildcards_and_a_malformed_broker_role" {
  command = plan
  variables {
    function_name   = "96bulls-*"
    log_group_name  = "/aws/lambda/*"
    broker_role_arn = "arn:aws:iam::222222222222:role/*"
  }
  expect_failures = [var.function_name, var.log_group_name, var.broker_role_arn]
}
