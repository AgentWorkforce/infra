mock_provider "helm" {}

mock_provider "kubernetes" {}

variables {
  admin_credentials_secret_name = "opensearch-admin"
  security_config_secret_name   = "opensearch-security-config"
  network_policy = {
    allowed_namespaces = ["agent-relay"]
  }
}

run "defaults_are_tls_and_private" {
  command = apply

  assert {
    condition     = yamldecode(helm_release.cluster.values[0]).cluster.security.tls.http.generate && yamldecode(helm_release.cluster.values[0]).cluster.security.tls.transport.generate
    error_message = "TLS on HTTP and transport."
  }
  assert {
    condition     = yamldecode(helm_release.cluster.values[0]).cluster.security.config.adminCredentialsSecret.name == "opensearch-admin"
    error_message = "Admin credentials come from an existing Secret."
  }
  assert {
    condition     = yamldecode(helm_release.cluster.values[0]).cluster.dashboards.enable == false
    error_message = "Dashboards off by default."
  }
  assert {
    condition     = yamldecode(helm_release.cluster.values[0]).cluster.nodePools[0].replicas == 3
    error_message = "Three nodes by default."
  }
  assert {
    condition     = length(kubernetes_network_policy_v1.this[0].spec[0].ingress) == 2 && length(kubernetes_network_policy_v1.this[0].spec[0].ingress[1].from) == 2 && kubernetes_network_policy_v1.this[0].spec[0].ingress[1].ports[0].port == "9200"
    error_message = "NetworkPolicy admits the namespace on all ports, and the operator and allowed namespaces on 9200 only."
  }
  assert {
    condition     = output.url == "https://relay-search.opensearch.svc:9200"
    error_message = "HTTPS in-cluster URL."
  }
}

run "admin_secret_required" {
  command = plan

  variables {
    admin_credentials_secret_name = ""
  }

  expect_failures = [var.admin_credentials_secret_name]
}

run "security_config_secret_required" {
  command = plan

  variables {
    security_config_secret_name = ""
  }

  expect_failures = [var.security_config_secret_name]
}

run "name_cannot_end_with_hyphen" {
  command = plan

  variables {
    name = "relay-search-"
  }

  expect_failures = [var.name]
}

run "dashboards_port_opened_when_enabled" {
  command = plan

  variables {
    dashboards_enabled = true
  }

  assert {
    condition     = toset([for p in kubernetes_network_policy_v1.this[0].spec[0].ingress[1].ports : p.port]) == toset(["9200", "5601"])
    error_message = "With Dashboards on, allowed namespaces reach 9200 and 5601."
  }
}
