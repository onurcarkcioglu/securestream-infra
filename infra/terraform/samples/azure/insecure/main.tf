# DELIBERATELY INSECURE - scan target only. Never run terraform init/plan/apply here.
# Findings expected: storage account with public access, NSG open to the internet, web app without HTTPS.
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "sample" {
  name     = "rg-securestream-sample-insecure"
  location = "westeurope"
}

resource "azurerm_storage_account" "media" {
  name                            = "sssampleinsecure"
  resource_group_name             = azurerm_resource_group.sample.name
  location                        = azurerm_resource_group.sample.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_0"
  https_traffic_only_enabled      = false
  allow_nested_items_to_be_public = true
  public_network_access_enabled   = true
}

resource "azurerm_network_security_group" "bastion" {
  name                = "nsg-sample-insecure"
  location            = azurerm_resource_group.sample.location
  resource_group_name = azurerm_resource_group.sample.name

  security_rule {
    name                       = "ssh-rdp-from-anywhere"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_service_plan" "web" {
  name                = "plan-sample-insecure"
  location            = azurerm_resource_group.sample.location
  resource_group_name = azurerm_resource_group.sample.name
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "catalog" {
  name                = "app-securestream-sample-insecure"
  location            = azurerm_resource_group.sample.location
  resource_group_name = azurerm_resource_group.sample.name
  service_plan_id     = azurerm_service_plan.web.id
  https_only          = false

  site_config {
    minimum_tls_version = "1.0"
    ftps_state          = "AllAllowed"
  }
}
