terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=5.0.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "=4.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.9.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "=2.9.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "=3.6.0"
    }
  }
}
