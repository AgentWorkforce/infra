locals {
  # Compare whole intervals, not just network addresses, including nested ranges.
  ranges = { for key, cidr in merge({ connector = var.connector_cidr }, {
    for i, cidr in var.existing_network_cidrs : "existing-${i}" => cidr
    }) : key => {
    first = sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
    last  = sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  } }
  private_ranges = [
    { first = 167772160, last = 184549375 },
    { first = 2886729728, last = 2887778303 },
    { first = 3232235520, last = 3232301055 }
  ]
  private_connector = anytrue([for r in local.private_ranges : local.ranges.connector.first >= r.first && local.ranges.connector.last <= r.last])
  no_overlap = alltrue([for key, r in local.ranges : key == "connector" ||
    local.ranges.connector.last < r.first || local.ranges.connector.first > r.last
  ])
}

data "azurerm_client_config" "this" { count = var.enabled ? 1 : 0 }
data "azurerm_virtual_network" "this" {
  count               = var.enabled ? 1 : 0
  name                = var.virtual_network_name
  resource_group_name = var.resource_group_name
}
locals {
  tags = merge(var.tags, { managed-by = "terraform" })
  vnet_ranges = var.enabled ? [for cidr in data.azurerm_virtual_network.this[0].address_space : {
    first = sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
    last  = sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  } if can(cidrnetmask(cidr))] : []
}
resource "terraform_data" "guard" {
  count = var.enabled ? 1 : 0
  input = var.connector_cidr
  lifecycle {
    precondition {
      condition     = data.azurerm_client_config.this[0].subscription_id == var.subscription_id
      error_message = "Provider subscription does not match the independently approved subscription."
    }
    precondition {
      condition     = local.private_connector && local.no_overlap && anytrue([for r in local.vnet_ranges : local.ranges.connector.first >= r.first && local.ranges.connector.last <= r.last])
      error_message = "Connector must be unused RFC1918 space within the VNet, disjoint from every supplied routed range."
    }
    precondition {
      condition     = length(var.outbound_rules) <= 100
      error_message = "At most 100 explicit outbound rules are supported."
    }
  }
}
resource "azurerm_subnet" "connector" {
  count                           = var.enabled ? 1 : 0
  name                            = "${var.name}-vpn-connector"
  resource_group_name             = var.resource_group_name
  virtual_network_name            = var.virtual_network_name
  address_prefixes                = [var.connector_cidr]
  default_outbound_access_enabled = false
  depends_on                      = [terraform_data.guard]
}
resource "azurerm_public_ip" "egress" {
  count               = var.enabled ? 1 : 0
  name                = "${var.name}-vpn-egress"
  location            = data.azurerm_virtual_network.this[0].location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
  depends_on          = [terraform_data.guard]
}
resource "azurerm_nat_gateway" "this" {
  count               = var.enabled ? 1 : 0
  name                = "${var.name}-vpn-egress"
  location            = data.azurerm_virtual_network.this[0].location
  resource_group_name = var.resource_group_name
  sku_name            = "Standard"
  tags                = local.tags
  depends_on          = [terraform_data.guard]
}
resource "azurerm_nat_gateway_public_ip_association" "this" {
  count                = var.enabled ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.egress[0].id
}
resource "azurerm_subnet_nat_gateway_association" "this" {
  count          = var.enabled ? 1 : 0
  subnet_id      = azurerm_subnet.connector[0].id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
  depends_on     = [azurerm_nat_gateway_public_ip_association.this]
}
resource "azurerm_network_security_group" "connector" {
  count               = var.enabled ? 1 : 0
  name                = "${var.name}-vpn-connector"
  location            = data.azurerm_virtual_network.this[0].location
  resource_group_name = var.resource_group_name
  tags                = local.tags
  depends_on          = [terraform_data.guard]
}
resource "azurerm_network_security_rule" "outbound" {
  for_each                    = var.enabled ? var.outbound_rules : {}
  name                        = "out-${each.key}"
  priority                    = 100 + index(sort(keys(var.outbound_rules)), each.key)
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = title(each.value.protocol)
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.port)
  source_address_prefix       = var.connector_cidr
  destination_address_prefix  = each.value.cidr
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.connector[0].name
}
resource "azurerm_network_security_rule" "deny" {
  for_each                    = var.enabled ? toset(["Inbound", "Outbound"]) : toset([])
  name                        = "deny-${lower(each.key)}"
  priority                    = 4096
  direction                   = each.key
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.connector[0].name
}
resource "azurerm_subnet_network_security_group_association" "this" {
  count                     = var.enabled ? 1 : 0
  subnet_id                 = azurerm_subnet.connector[0].id
  network_security_group_id = azurerm_network_security_group.connector[0].id
  depends_on                = [azurerm_network_security_rule.deny]
}
