# Configure Providers

provider "random" {
  version         = "~> 2.0"
}

provider "azurerm" {
  version         = "~> 1.20"
  subscription_id = "${var.subscription_id}"
  client_id       = "${var.client_id}"
  client_secret   = "${var.client_secret}"
  tenant_id       = "${var.tenant_id}"
}

provider "azuread" {
  version = "=0.1.0"
  subscription_id = "${var.subscription_id}"
  client_id       = "${var.client_id}"
  client_secret   = "${var.client_secret}"
  tenant_id       = "${var.tenant_id}"
}
variable "installation_name" {
  default = "aks-contour"
}

variable "subscription_id" {
  type = "string"
}

variable "client_id" {
  type = "string"
}

variable "client_ip_address" {
   type = "string"
}

variable "client_secret" {
  type = "string"
}

variable "tenant_id" {
  type = "string"
}

variable "cluster_admin_user" {
  default = "clusteradmin"
}

variable "cluster_ssh_key_data" {
  type = "string"
}

variable "location" {
  default = "eastus2"
}

variable "cluster_agent_count" {
  default = 2
}

variable "cluster_agent_vm_size" {
  default = "Standard_D2s_v3"
}

variable "cluster_agent_disk_size_gb" {
  default = 30
}

variable "kubernetes_version" {
  default = "1.11.4"
}

variable "cluster_name" {
  type = "string"
}

variable "cluster_dns_prefix" {
  type = "string"
}

variable "wordpress_database_name" {
  type = "string"
}

variable "create_dns" {
  default = false
}

variable "use_keyvault" {
  default = false
}

variable  "keyvault_name" {
  type = "string"
}


resource "random_string" "name_suffix" {
  length  = 15
  special = false
  upper   = false
  number  = false
  keepers = {
    resource_group = "${var.installation_name}"
    location       = "${var.location}"
  }
}

locals {
  cluster_name       = "${length(var.cluster_name)==0 ? "aks-${random_string.name_suffix.result}": var.cluster_name}"
  kv_name       = "${length(var.keyvault_name)==0 ? "kv${random_string.name_suffix.result}":var.keyvault_name}"
  cluster_dns_prefix = "${length(var.cluster_dns_prefix)==0 ? random_string.name_suffix.result : var.cluster_dns_prefix}"
  wordpress_domain_name_label="${length(var.cluster_dns_prefix)==0 ? "wp-${random_string.name_suffix.result}" : "wp-${var.cluster_dns_prefix}"}" 
}

resource "azurerm_resource_group" "k8s" {
  name     = "${var.installation_name}"
  location = "${var.location}"
}

// TODO: Enable VNet deployment

resource "azurerm_kubernetes_cluster" "k8s" {
  name                = "${local.cluster_name}"
  location            = "${azurerm_resource_group.k8s.location}"
  resource_group_name = "${azurerm_resource_group.k8s.name}"
  dns_prefix          = "${local.cluster_dns_prefix}"
  kubernetes_version  = "${var.kubernetes_version}"

  linux_profile {
    admin_username = "${var.cluster_admin_user}"
    ssh_key {
      key_data = "${var.cluster_ssh_key_data}"
    }
  }

  agent_pool_profile {
    name            = "default"
    count           = "${var.cluster_agent_count}"
    vm_size         = "${var.cluster_agent_vm_size}"
    os_type         = "Linux"
    os_disk_size_gb = "${var.cluster_agent_disk_size_gb}"
  }

  service_principal {
    client_id     = "${var.client_id}"
    client_secret = "${var.client_secret}"
  }
 # This should be supported in 1.20 of TF provider.
  role_based_access_control {
    enabled = true
  }

}
data "azuread_service_principal" "sp" {
  application_id = "${var.client_id}"
}

resource "azurerm_key_vault" "cert_vault" {
  count                       = "${var.use_keyvault?1:0}"
  name                        = "${local.kv_name}"
  location                    = "${azurerm_resource_group.k8s.location}"
  resource_group_name         = "${azurerm_resource_group.k8s.name}"
  tenant_id                   = "${var.tenant_id}"
  sku {
    name = "standard"
  }

  access_policy {
    tenant_id = "${var.tenant_id}"
    object_id = "${data.azuread_service_principal.sp.id}"

    certificate_permissions = [
      "get","create","update","import"
    ]

    secret_permissions = [
      "get","set"
    ]
  }

  network_acls {
    default_action = "Deny"
    bypass         = "None"
    ip_rules      = [
      "${var.client_ip_address}"
    ]
  }

}
resource "random_string" "sa_name" {
  length = 23
  special = false
  upper= false
  number=false
   keepers = {
        resource_group = "${azurerm_resource_group.k8s.name}"
        cluster_name = "${azurerm_kubernetes_cluster.k8s.name}"
        location="${azurerm_resource_group.k8s.location}"
   }
}

resource "azurerm_storage_account" "wordpress_files_account" {
  name                     = "${random_string.sa_name.result}"
  resource_group_name      = "${azurerm_kubernetes_cluster.k8s.node_resource_group}"
  location                 = "${azurerm_resource_group.k8s.location}"
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_share" "wp_filesshare" {
  name = "wpfilesshare"
  resource_group_name  = "${azurerm_kubernetes_cluster.k8s.node_resource_group}"
  storage_account_name = "${azurerm_storage_account.wordpress_files_account.name}"
  quota = 50
}

resource "azurerm_mysql_server" "wordpress_sql" {
  name                = "wp-sql-${random_string.name_suffix.result}"
  resource_group_name = "${azurerm_resource_group.k8s.name}"
  location            = "${azurerm_resource_group.k8s.location}"
  
  sku {
    name     = "GP_Gen5_2"
    capacity = 2
    tier     = "GeneralPurpose"
    family   = "Gen5"
  }

  storage_profile {
    storage_mb            = 5120
    backup_retention_days = 7
    geo_redundant_backup  = "Disabled"
  }

  administrator_login          = "wpadmin"
  administrator_login_password = "${bcrypt("${uuid()}",12)}"
  version                      = "5.7"

# TODO: set up Wordpress to use an TLS connection

  ssl_enforcement              = "Disabled"
  lifecycle {
    ignore_changes=["administrator_login_password"]
  }
}

resource "azurerm_public_ip" "aks_public_ip" {
  name                          = "aks_public_ip"
  resource_group_name           = "${azurerm_kubernetes_cluster.k8s.node_resource_group}"
  location                      = "${azurerm_resource_group.k8s.location}"
  allocation_method             = "Static"
  domain_name_label             ="${local.wordpress_domain_name_label}"
}

resource "azurerm_mysql_firewall_rule" "egress_ip" {
  name                = "egress_ip"
  resource_group_name = "${azurerm_resource_group.k8s.name}"
  server_name         = "${azurerm_mysql_server.wordpress_sql.name}"
  start_ip_address    = "${azurerm_public_ip.aks_public_ip.ip_address}"
  end_ip_address      = "${azurerm_public_ip.aks_public_ip.ip_address}"
}

resource "azurerm_mysql_database" "wordpress_db" {
  name                = "${var.wordpress_database_name}"
  resource_group_name = "${azurerm_resource_group.k8s.name}"
  server_name         = "${azurerm_mysql_server.wordpress_sql.name}"
  charset             = "utf8"
  collation           = "utf8_unicode_ci"
}

output "resource_group_name" {
  value = "${azurerm_resource_group.k8s.name}"
}
output "cluster_name" {
  value = "${azurerm_kubernetes_cluster.k8s.name}"
}
output "keyvault_name" {
  value = "${local.kv_name}"
}
output "file_share_name" {
  value = "${azurerm_storage_share.wp_filesshare.name}"
}
output "file_share_storage_account_name" {
  value = "${azurerm_storage_account.wordpress_files_account.name}"
}
output "file_share_storage_account_key" {
  value = "${azurerm_storage_account.wordpress_files_account.primary_access_key}"
}
output "externalDatabase_host" {
    value = "${azurerm_mysql_server.wordpress_sql.fqdn}"
}
output  "externalDatabase_user" {
  value = "${azurerm_mysql_server.wordpress_sql.administrator_login}@${azurerm_mysql_server.wordpress_sql.name}"
}
output "externalDatabase_password" {
  value = "${azurerm_mysql_server.wordpress_sql.administrator_login_password}"
}
output  "externalDatabase_database" {
  value = "${azurerm_mysql_database.wordpress_db.name}"
}
output  "public_ip_address" {
  value = "${azurerm_public_ip.aks_public_ip.ip_address}"
}
output  "fqdn" {
  value = "${azurerm_public_ip.aks_public_ip.fqdn}"
}