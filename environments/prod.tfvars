# environments/prod.tfvars
# This is the LIVE, already-deployed environment. Values intentionally match
# the original (pre-multi-env) configuration so `terraform plan` shows zero
# infrastructure changes when this is applied — only the `default_tags`
# Environment/Project tags are new.

environment = "prod"

vpc_cidr = "10.0.0.0/16"

ec2_instance_type    = "t3.micro"
asg_min_size         = 2
asg_max_size         = 4
asg_desired_capacity = 2

db_instance_class    = "db.t3.micro"
db_allocated_storage = 20
