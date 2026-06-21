# locals.tf
# Central naming convention so every resource name/tag is environment-aware.
# Example: project_name="aws-self-healing-infra", environment="dev"
#          -> name_prefix = "aws-self-healing-infra-dev"

locals {
  # IMPORTANT: prod keeps the ORIGINAL unsuffixed naming convention
  # ("aws-self-healing-infra-xxx") because that is what's already deployed
  # and tracked in state. If prod also got a "-prod" suffix, every resource
  # name/identifier would change and `terraform plan` would propose
  # destroying and recreating the live production infrastructure (RDS
  # included). dev/staging are brand-new stacks, so they get a clean
  # "-dev"/"-staging" suffix with no such risk.
  name_prefix = var.environment == "prod" ? var.project_name : "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
