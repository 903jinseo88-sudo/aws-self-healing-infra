# environments/staging.tfvars
# Ephemeral, demo-only environment. Closer to prod sizing than dev (useful if
# you want to show a "pre-prod validation" story), but still spun
# up/destroyed on demand rather than left running.

environment = "staging"

vpc_cidr = "10.2.0.0/16"

ec2_instance_type    = "t3.micro"
asg_min_size         = 1
asg_max_size         = 2
asg_desired_capacity = 1

db_instance_class    = "db.t3.micro"
db_allocated_storage = 20
