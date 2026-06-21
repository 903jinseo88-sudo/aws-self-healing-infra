# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# Public Subnets
#tfsec:ignore:aws-ec2-no-public-ip-subnet
# Required so the ALB (in this public subnet) is internet-reachable.
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone       = "ap-southeast-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-a"
  }
}

#tfsec:ignore:aws-ec2-no-public-ip-subnet
# Required so the ALB (in this public subnet) is internet-reachable.
resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 2)
  availability_zone       = "ap-southeast-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-b"
  }
}

# Private Subnets
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 11)
  availability_zone = "ap-southeast-1a"

  tags = {
    Name = "${local.name_prefix}-private-a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 12)
  availability_zone = "ap-southeast-1b"

  tags = {
    Name = "${local.name_prefix}-private-b"
  }
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "${local.name_prefix}-nat-gw"
  }

  depends_on = [aws_internet_gateway.main]
}

# Private Route Table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

#tfsec:ignore:aws-ec2-require-vpc-flow-logs-for-all-vpcs
# Flow Logs would add ongoing CloudWatch Logs cost; out of scope for this portfolio demo.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# Security Group for ALB
resource "aws_security_group" "alb" {
  # name forces replacement on change -> keep prod's original literal name
  # untouched so this refactor doesn't recreate the live SG.
  name        = var.environment == "prod" ? "alb-sg" : "${local.name_prefix}-alb-sg"
  description = "Allow HTTP traffic to ALB"
  vpc_id      = aws_vpc.main.id

  #tfsec:ignore:aws-ec2-no-public-ingress-sgr
  # Portfolio demo: ALB is intentionally internet-facing on port 80.
  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  #tfsec:ignore:aws-ec2-no-public-egress-sgr
  # Outbound traffic left open for OS/package updates on the instances.
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

# Security Group for EC2
resource "aws_security_group" "ec2" {
  name        = var.environment == "prod" ? "ec2-sg" : "${local.name_prefix}-ec2-sg"
  description = "Allow HTTP from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  #tfsec:ignore:aws-ec2-no-public-egress-sgr
  # Outbound traffic left open for OS/package updates on the instances.
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-ec2-sg"
  }
}

# Get latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# Launch Template
resource "aws_launch_template" "app" {
  name_prefix   = "${local.name_prefix}-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.ec2_instance_type

  vpc_security_group_ids = [aws_security_group.ec2.id]

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y httpd
    systemctl enable httpd
    systemctl start httpd
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    echo "<h1>Self-Healing Infra - Served by instance: $INSTANCE_ID</h1>" > /var/www/html/index.html
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name_prefix}-instance"
    }
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "app" {
  name                      = "${local.name_prefix}-asg"
  vpc_zone_identifier       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  health_check_type         = "ELB"
  health_check_grace_period = 60

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.app.arn]

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-asg-instance"
    propagate_at_launch = true
  }
}
# -----------------------------
# ALB Access Logs - S3 Bucket
# -----------------------------
data "aws_caller_identity" "current" {}

#tfsec:ignore:aws-s3-enable-bucket-logging
# This bucket *is* the log destination (ALB access logs). Logging access to
# the log bucket itself adds cost/complexity with little portfolio value.
resource "aws_s3_bucket" "alb_logs" {
  bucket = "${local.name_prefix}-alb-logs-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${local.name_prefix}-alb-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

#tfsec:ignore:aws-s3-encryption-customer-key
# ALB access log delivery only supports SSE-S3 (AES256), not SSE-KMS:
# https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

locals {
  elb_account_id_ap_southeast_1 = "114774131450"
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowELBLogDelivery"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.elb_account_id_ap_southeast_1}:root"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/alb-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid    = "AllowELBLogDeliveryService"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/alb-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# Application Load Balancer
#tfsec:ignore:aws-elb-alb-not-public
# Portfolio demo: ALB is intentionally public-facing to serve the web app.
resource "aws_lb" "app" {
  name                       = "${local.name_prefix}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb-logs"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# Target Group
resource "aws_lb_target_group" "app" {
  name     = "${local.name_prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 15
    timeout             = 5
  }

  tags = {
    Name = "${local.name_prefix}-tg"
  }
}

# Listener
#tfsec:ignore:aws-elb-http-not-used
# Portfolio demo: no domain/ACM certificate provisioned, so HTTPS is out of
# scope. In production this listener would redirect to a 443 HTTPS listener.
resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Security Group for RDS
resource "aws_security_group" "rds" {
  name        = var.environment == "prod" ? "rds-sg" : "${local.name_prefix}-rds-sg"
  description = "Allow MySQL access from EC2 only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  #tfsec:ignore:aws-ec2-no-public-egress-sgr
  # Outbound traffic left open; RDS has no internet-facing inbound access.
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-rds-sg"
  }
}

# DB Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = {
    Name = "${local.name_prefix}-db-subnet-group"
  }
}

# RDS Instance
resource "aws_db_instance" "main" {
  identifier                          = "${local.name_prefix}-db"
  engine                              = "mysql"
  engine_version                      = "8.0"
  instance_class                      = var.db_instance_class
  allocated_storage                   = var.db_allocated_storage
  storage_type                        = "gp3"
  storage_encrypted                   = true
  iam_database_authentication_enabled = true

  db_name  = "appdb"
  username = "admin"
  password = var.db_password

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name

  multi_az                     = false
  publicly_accessible          = false
  skip_final_snapshot          = true
  backup_retention_period = 7

  #tfsec:ignore:aws-rds-enable-performance-insights
  # Toggling this on a live RDS instance can trigger a reboot; deferring to
  # avoid a prod restart for a LOW-severity monitoring nice-to-have.
  performance_insights_enabled = false
  deletion_protection          = true

  tags = {
    Name = "${local.name_prefix}-db"
  }
}

# SNS Topic for alerts
#tfsec:ignore:aws-sns-topic-encryption-use-cmk
resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-alerts"
  kms_master_key_id = aws_kms_alias.sns.target_key_id
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# CloudWatch Alarm: Unhealthy hosts on the ALB Target Group
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name_prefix}-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0

  dimensions = {
    TargetGroup  = aws_lb_target_group.app.arn_suffix
    LoadBalancer = aws_lb.app.arn_suffix
  }

  alarm_description = "Triggers when one or more EC2 instances behind the ALB become unhealthy"
  alarm_actions     = [aws_sns_topic.alerts.arn]
  ok_actions        = [aws_sns_topic.alerts.arn]
}

# CloudWatch Alarm: ASG scaling activity (informational)
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${local.name_prefix}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 70

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_description = "Triggers when average CPU utilization across the ASG exceeds 70%"
  alarm_actions     = [aws_sns_topic.alerts.arn]
}

# -----------------------------
# Lambda Auto-Remediation
# -----------------------------
data "archive_file" "auto_remediation" {
  type        = "zip"
  source_file = "${path.module}/lambda/auto_remediation/lambda_function.py"
  output_path = "${path.module}/lambda/auto_remediation.zip"
}

#tfsec:ignore:aws-dynamodb-table-customer-key
# This table only holds transient remediation-cooldown timestamps (no
# sensitive data); AWS-owned default encryption is sufficient here.
resource "aws_dynamodb_table" "remediation_cooldown" {
  name         = "${local.name_prefix}-remediation-cooldown"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "instance_id"

  attribute {
    name = "instance_id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name = "${local.name_prefix}-remediation-cooldown"
  }
}

resource "aws_iam_role" "lambda_remediation" {
  name = "${local.name_prefix}-lambda-remediation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_remediation" {
  name = "${local.name_prefix}-lambda-remediation-policy"
  role = aws_iam_role.lambda_remediation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Reboot"
        Effect = "Allow"
        Action = [
          "ec2:RebootInstances",
          "ec2:DescribeInstanceStatus"
        ]
        Resource = "*"
      },
      {
        Sid    = "ELBDescribe"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeTargetHealth"
        ]
        Resource = "*"
      },
      {
        Sid    = "DynamoDBCooldown"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.remediation_cooldown.arn
      },
      {
        Sid    = "SNSPublish"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid    = "KMSForSNS"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = aws_kms_key.sns.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:ap-southeast-1:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "auto_remediation" {
  function_name    = "${local.name_prefix}-auto-remediation"
  role             = aws_iam_role.lambda_remediation.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.auto_remediation.output_path
  source_code_hash = data.archive_file.auto_remediation.output_base64sha256

  environment {
    variables = {
      COOLDOWN_TABLE   = aws_dynamodb_table.remediation_cooldown.name
      TARGET_GROUP_ARN = aws_lb_target_group.app.arn
      SNS_TOPIC_ARN    = aws_sns_topic.alerts.arn
      COOLDOWN_MINUTES = "10"
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = {
    Name = "${local.name_prefix}-auto-remediation"
  }
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_remediation.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "lambda_remediation" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.auto_remediation.arn
}

# -----------------------------
# KMS Key for SNS Topic Encryption
# -----------------------------
resource "aws_kms_key" "sns" {
  description             = "KMS key for SNS topic encryption (${local.name_prefix}-alerts)"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchAlarmsToUseKey"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSNSServiceToUseKey"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-sns-kms"
  }
}

resource "aws_kms_alias" "sns" {
  name          = "alias/${local.name_prefix}-sns"
  target_key_id = aws_kms_key.sns.key_id
}
