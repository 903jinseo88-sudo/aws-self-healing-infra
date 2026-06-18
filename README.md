# Self-Healing 3-Tier Web Infrastructure on AWS

A production-style AWS infrastructure project built entirely with Terraform, designed to automatically detect and recover from instance failure with zero downtime. Every resource was deployed, tested, and torn down using Infrastructure as Code — no manual console clicks.

## Architecture

```
                         Internet
                            │
                   ┌────────▼────────┐
                   │  Application LB  │  (public subnets)
                   └────────┬────────┘
                            │
              ┌─────────────┴─────────────┐
              │                           │
       ┌──────▼──────┐            ┌──────▼──────┐
       │   EC2 (AZ-a) │            │  EC2 (AZ-b)  │  (private subnets,
       │  Auto Scaling│            │ Auto Scaling │   Amazon Linux 2023)
       └──────┬──────┘            └──────┬──────┘
              │                           │
              └─────────────┬─────────────┘
                             │
                      ┌──────▼──────┐
                      │  RDS (MySQL) │  (private subnets)
                      └─────────────┘

       CloudWatch Alarms ──► SNS ──► Email Notification
```

## What This Project Demonstrates

**Scenario:** an EC2 instance behind the load balancer becomes unhealthy or is terminated unexpectedly.

1. The Application Load Balancer continuously health-checks all registered instances
2. CloudWatch monitors the `UnHealthyHostCount` metric on the target group
3. When an instance fails, the Auto Scaling Group detects it and launches a replacement automatically
4. The ALB stops routing traffic to the unhealthy instance and shifts it to healthy ones
5. CloudWatch triggers an SNS alarm, sending a real-time email notification
6. The application remains available throughout — zero downtime, zero manual intervention

This was not just configured — it was tested by force-terminating a live, healthy instance and observing the full recovery loop end-to-end. See [Disaster Recovery Test](#disaster-recovery-test) below.

## Infrastructure Components

| Layer | Service | Configuration |
|---|---|---|
| Network | VPC | `10.0.0.0/16`, 2 public + 2 private subnets across 2 AZs |
| Network | Internet Gateway / NAT Gateway | Public subnets route via IGW, private subnets via NAT |
| Compute | EC2 (Auto Scaling Group) | Amazon Linux 2023, min 2 / max 4, t3.micro |
| Load Balancing | Application Load Balancer | HTTP listener, health checks every 15s |
| Database | RDS (MySQL 8.0) | Private subnets only, no public access, t3.micro |
| Monitoring | CloudWatch Alarms | Unhealthy host count, CPU utilization |
| Alerting | SNS | Email notifications on alarm/recovery |
| IaC | Terraform | All resources defined as code, fully reproducible |

## Security Design

- EC2 instances live in **private subnets** — no direct internet access, no public IP
- RDS is **not publicly accessible** and only reachable from EC2 on port 3306
- Security groups follow least privilege: ALB accepts HTTP from the internet, EC2 only accepts traffic from the ALB's security group, RDS only accepts traffic from EC2's security group
- Database credentials are passed as a sensitive Terraform variable, never hardcoded or committed to version control

## Disaster Recovery Test

To validate that the self-healing design actually works (not just that it's configured correctly on paper), I deliberately terminated a healthy, in-service EC2 instance and observed the recovery process in real time.

**Result:**
- The Auto Scaling Group detected the missing instance within seconds and launched a replacement automatically
- The ALB continued routing traffic to the remaining healthy instance throughout the recovery
- Refreshing the application during the test never returned an error — requests were served by the surviving instance and, shortly after, by the newly launched replacement
- The system stabilized back to 2 healthy instances with no manual intervention

Full write-up with screenshots and terminal output: [AWS Self-Healing Infrastructure — Build Log](https://jinseocloudportfolio.notion.site/AWS-Self-Healing-Infrastrcturture-Build-Log-383b9106b30380c489d7e84749425711?source=copy_link)

## Repository Structure

```
.
├── main.tf          # All AWS resources (VPC, subnets, ALB, ASG, RDS, CloudWatch, SNS)
├── variables.tf     # Input variables (region, db password, alert email)
├── outputs.tf       # Useful outputs (VPC ID, ALB DNS name, RDS endpoint)
├── provider.tf      # Terraform + AWS provider configuration
└── README.md
```

## Running This Project

```bash
terraform init
terraform plan
terraform apply
```

You will be prompted for `db_password` and `alert_email` (both marked sensitive, not stored in the repo).

To tear down all resources:

```bash
terraform destroy
```

## Tech Stack

AWS (VPC, EC2, Auto Scaling, ALB, RDS, CloudWatch, SNS, IAM) · Terraform · Amazon Linux 2023

## Author

Lee Jinseo — [LinkedIn](https://www.linkedin.com/in/jinseo-lee-47bb0931a) · [Notion Build Log](https://jinseocloudportfolio.notion.site/AWS-Self-Healing-Infrastrcturture-Build-Log-383b9106b30380c489d7e84749425711?source=copy_link)
