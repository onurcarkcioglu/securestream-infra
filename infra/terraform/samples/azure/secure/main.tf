# Secure counterpart of ../insecure: same resources, configured correctly. Scan target only.
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "sample" {
  name     = "rg-securestream-sample-secure"
  location = "westeurope"
}

resource "azurerm_storage_account" "media" {
  name                            = "sssamplesecure"
  resource_group_name             = azurerm_resource_group.sample.name
  location                        = azurerm_resource_group.sample.location
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false
  shared_access_key_enabled       = false
  local_user_enabled              = false

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  sas_policy {
    expiration_period = "01.00:00:00"
  }

  queue_properties {
    logging {
      delete                = true
      read                  = true
      write                 = true
      version               = "1.0"
      retention_policy_days = 30
    }
  }

  identity {
    type = "SystemAssigned"
  }
}

# Customer-managed key from Key Vault instead of the platform-managed default.
resource "azurerm_storage_account_customer_managed_key" "media" {
  storage_account_id = azurerm_storage_account.media.id
  key_vault_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sec/providers/Microsoft.KeyVault/vaults/kv-securestream"
  key_name           = "storage-media"
}

# Reachable only through a private endpoint in the lab VNet.
resource "azurerm_private_endpoint" "media_blob" {
  name                = "pe-sssamplesecure-blob"
  location            = azurerm_resource_group.sample.location
  resource_group_name = azurerm_resource_group.sample.name
  subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-lab/subnets/private-endpoints"

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.media.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }
}

resource "azurerm_network_security_group" "bastion" {
  name                = "nsg-sample-secure"
  location            = azurerm_resource_group.sample.location
  resource_group_name = azurerm_resource_group.sample.name

  security_rule {
    name                       = "ssh-from-admin-vpn"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.10.0.0/16"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_service_plan" "web" {
  name                   = "plan-sample-secure"
  location               = azurerm_resource_group.sample.location
  resource_group_name    = azurerm_resource_group.sample.name
  os_type                = "Linux"
  sku_name               = "P1v3"
  worker_count           = 3
  zone_balancing_enabled = true
}

resource "azurerm_linux_web_app" "catalog" {
  name                          = "app-securestream-sample-secure"
  location                      = azurerm_resource_group.sample.location
  resource_group_name           = azurerm_resource_group.sample.name
  service_plan_id               = azurerm_service_plan.web.id
  https_only                    = true
  client_certificate_enabled    = true
  public_network_access_enabled = false
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  identity {
    type = "SystemAssigned"
  }

  site_config {
    minimum_tls_version = "1.2"
    ftps_state          = "Disabled"
    http2_enabled       = true
    health_check_path   = "/healthz"
    health_check_eviction_time_in_min = 5
  }

  logs {
    detailed_error_messages = true
    failed_request_tracing  = true
    http_logs {
      file_system {
        retention_in_days = 30
        retention_in_mb   = 35
      }
    }
  }

  auth_settings_v2 {
    auth_enabled           = true
    require_authentication = true
    unauthenticated_action = "Return401"
    default_provider       = "azureactivedirectory"
    active_directory_v2 {
      client_id            = "00000000-0000-0000-0000-000000000000"
      tenant_auth_endpoint = "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0"
    }
    login {}
  }
}
