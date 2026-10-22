# catalog uygulamasi yalnizca kendi secret'larini OKUYABILIR.
path "secret/data/catalog/*" {
  capabilities = ["read"]
}
