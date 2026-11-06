# モジュール単体の検証で使うバージョン制約
# scripts/check.sh がモジュールの複製へ持ち込む。ラボからは参照しない
#
# ラボの terraform.tf から借りると、ラボが増えたときに「先頭のルート」が変わり、
# 宣言のないプロバイダが制約なしで解決される
# check.sh の version 検査が、全ラボの制約とこのファイルの一致を確かめる
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
    azapi = {
      source  = "Azure/azapi"
      version = "=2.11.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "=3.6.0"
    }
  }
}
