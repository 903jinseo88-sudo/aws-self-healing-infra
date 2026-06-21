# environments/backend-prod.hcl
# Same key as the original single-environment setup -> no state migration,
# no risk to the live infrastructure.
key = "terraform.tfstate"
