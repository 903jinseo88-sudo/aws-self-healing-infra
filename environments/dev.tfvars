# environments/dev.tfvars
# Ephemeral, demo-only environment. Spin up to capture evidence/screenshots,
# then destroy via the "Terraform Destroy (dev/staging)" GitHub Actions
# workflow to avoid ongoing cost. Sized down from prod where it's safe to.

environment = "dev"

vpc_cidr = "10.1.0.0/16"

ec2_instance_type    = "t3.micro"
asg_min_size         = 1
asg_max_size         = 2
asg_desired_capacity = 1

db_instance_class    = "db.t3.micro"
db_allocated_storage = 20
