# Self-Healing 3-Tier Web Infrastructure on AWS

A production-style AWS infrastructure project built entirely with Terraform, designed to automatically detect and recover from instance failure with zero downtime — and deployed through a CI/CD pipeline with an automated security gate and a manual approval step before anything reaches production. Every resource was deployed, tested, and torn down using Infrastructure as Code — no manual console clicks.

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

```
GitHub Actions CI/CD
  push to main / pull_request
        │
        ▼
  terraform plan ──► tfsec security scan ──► manual approval (production env) ──► terraform apply
                            │                         │
                       blocks on findings      required reviewer, main-branch only,
                                                admin bypass disabled
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

**Scenario two:** infrastructure changes are now deployed through a pipeline, not a laptop.

1. A change is pushed to `main` (or opened as a pull request)
2. GitHub Actions authenticates to AWS via OIDC — no long-lived access keys stored anywhere
3. `terraform plan` runs against remote state (S3 + DynamoDB locking)
4. `tfsec` scans the plan for security misconfigurations and **blocks the pipeline** if it finds any
5. If the scan passes, the pipeline pauses and waits for manual approval in the `production` GitHub environment
6. Only after a human approves does `terraform apply` run, applying the exact plan that was reviewed

This was tested by deliberately introducing a real vulnerability (an RDS security group opened to `0.0.0.0/0`) on a pull request and confirming the pipeline caught it and refused to proceed. See [CI/CD Pipeline & Security Gate](#cicd-pipeline--security-gate) below.

## Infrastructure Components

| Layer | Service | Configuration |
|---|---|---|
| Network | VPC | `10.0.0.0/16`, 2 public + 2 private subnets across 2 AZs |
| Network | Internet Gateway / NAT Gateway | Public subnets route via IGW, private subnets via NAT |
| Compute | EC2 (Auto Scaling Group) | Amazon Linux 2023, min 2 / max 4, t3.micro, IMDSv2 enforced |
| Load Balancing | Application Load Balancer | HTTP listener, health checks every 15s, invalid headers dropped |
| Database | RDS (MySQL 8.0) | Private subnets only, no public access, t3.micro, encrypted, deletion protection enabled |
| Monitoring | CloudWatch Alarms | Unhealthy host count, CPU utilization |
| Alerting | SNS | Email notifications on alarm/recovery, encrypted topic |
| IaC | Terraform | All resources defined as code, fully reproducible, remote state in S3 + DynamoDB |
| CI/CD | GitHub Actions | OIDC auth, tfsec security gate, manual approval before apply |

## Security Design

**Network & access:**
- EC2 instances live in **private subnets** — no direct internet access, no public IP
- RDS is **not publicly accessible** and only reachable from EC2 on port 3306
- Security groups follow least privilege: ALB accepts HTTP from the internet, EC2 only accepts traffic from the ALB's security group, RDS only accepts traffic from EC2's security group
- Database credentials are passed as a sensitive Terraform variable / GitHub Secret, never hardcoded or committed to version control
- EC2 launch template enforces **IMDSv2** (token-required metadata access)

**Pipeline & deployment:**
- AWS authentication uses **OIDC**, not static access keys — GitHub issues a short-lived token scoped to this exact repository and branch
- The IAM role's trust policy and permission policy are both scoped to the minimum needed (specific AWS services, specific S3 bucket, specific DynamoDB table — not `AdministratorAccess`)
- The `production` GitHub environment requires a human reviewer, restricts deployment to the `main` branch only, and has **admin bypass explicitly disabled** — the approval step cannot be skipped, even by the repo owner

## CI/CD Pipeline & Security Gate

Infrastructure changes go through a three-stage GitHub Actions pipeline (`.github/workflows/terraform-ci-cd.yml`):

1. **`terraform plan`** — runs against remote state, uploads the plan as an artifact
2. **`tfsec` security scan** — runs `tfsec` directly as a shell step (not a wrapper action — see note below) and fails the pipeline on any finding
3. **`terraform apply`** — only runs if both prior stages pass, downloads the exact reviewed plan artifact, and requires manual approval through the `production` environment before executing

**Proving the gate actually works:** I deliberately opened a pull request that exposed the RDS security group to `0.0.0.0/0` instead of restricting it to the application tier. The pipeline's `tfsec` scan caught it immediately:

```
ID: aws-ec2-no-public-ingress-sgr
Impact: Your port exposed to the internet
main.tf:151 — cidr_blocks = ["0.0.0.0/0"]
```

Because `terraform apply` depends on the scan passing, it never ran — the vulnerable configuration never reached AWS. The PR was closed without merging.

**A note on tooling:** getting `tfsec` to reliably fail the pipeline took more debugging than expected. The popular `aquasecurity/tfsec-action` reported success even when tfsec's own output showed 21 findings — its `soft_fail: false` input wasn't reliably propagating the exit code. The fix was to install and run the `tfsec` binary directly as a shell step, so GitHub Actions reads the real process exit code with no wrapper in between. This kind of "the tool isn't doing what the docs say it does" debugging is, in my experience, a normal and underrated part of building CI/CD — not a sign something was set up wrong.

**Triage, not just suppression:** running `tfsec` for real surfaced 20 pre-existing findings across the whole codebase, unrelated to the intentional demo bug. Each was individually reviewed:

| Disposition | Count | Examples |
|---|---|---|
| Fixed in code | 7 | IMDSv2 enforcement, ALB invalid-header dropping, RDS backup retention, RDS performance insights, SNS topic encryption, security group rule descriptions, SNS customer-managed KMS key |
| Accepted risk (documented, excluded) | 12 | ALB intentionally public-facing, HTTP listener (no domain/ACM cert in scope), VPC Flow Logs (cost) |
| Known drift (code-vs-live, deferred) | 1 | RDS storage encryption — code requires it, but the live instance predates the change; applying it forces a destroy-and-recreate, so it's tracked as a planned migration rather than silently applied (see Known Issues below) |

> Note: the SNS topic's KMS key was originally an AWS-managed key, accepted as a cost/complexity trade-off. It was later replaced with a customer-managed key in Phase 13 after discovering that CloudWatch Alarms couldn't be granted publish permissions on the AWS-managed key — see Auto-Remediation below.

The accepted-risk items are excluded via a `--exclude` list in the workflow (or enabled directly where Rego-based checks didn't respond to standard exclude syntax), each with a one-line reason in the code or workflow file — the goal being to show deliberate trade-offs, not blind suppression.

## Monitoring & Log Analysis

The ALB's access logs are delivered to a dedicated, encrypted S3 bucket (public access blocked, 30-day lifecycle expiration) and queried through an Amazon Athena external table built on a regex SerDe.

Five operational queries cover the kind of first-line diagnostic questions a Cloud Support engineer is typically asked to answer:

- 5xx error rate by hour
- Slowest requests (Top 10 by target processing time)
- Request volume by client IP / user agent
- Status code distribution (2xx / 4xx / 5xx)
- Average / max latency by URL

This closes a gap that pure auto-healing doesn't cover: instance-level health checks and alarms tell you *that* something failed, but not *what actually happened* during an incident. Querying real traffic also surfaced unsolicited scanning traffic from external IPs hitting the public ALB — a reminder that this is internet-facing infrastructure, and a candidate for future WAF rules or IP allow-listing in a production setting.

## Auto-Remediation (Lambda)

A Lambda function, triggered via the existing `unhealthy_hosts` CloudWatch alarm through SNS, adds a lighter-weight response option ahead of full Auto Scaling instance replacement:

1. On an `ALARM` state transition, the function queries the ALB target group for unhealthy/draining instances.
2. Each unhealthy instance is rebooted via the EC2 API — unless it's within a 10-minute cooldown window (tracked in DynamoDB per instance ID), which prevents repeated reboots on consecutive alarm evaluations.
3. The result is published back to the same SNS topic for visibility. A guard clause ensures the function ignores its own follow-up notification rather than treating it as a new alarm and re-triggering itself.

**Troubleshooting note:** the first end-to-end test failed silently — CloudWatch Alarms couldn't publish to the SNS topic because the topic was encrypted with an AWS-managed KMS key, which can't be granted explicit cross-service publish permissions. Replacing it with a customer-managed key (with an explicit key policy for `cloudwatch.amazonaws.com` and `sns.amazonaws.com`) fixed alarm delivery, but a second test then failed at the final notification step — the Lambda's own IAM role also needed `kms:GenerateDataKey`/`kms:Decrypt` on that key, since a service principal's key policy permissions don't extend to a role acting on that service's behalf. A third test run completed end to end with no errors, correctly distinguishing newly-unhealthy instances (`REBOOTED`) from ones still in cooldown (`SKIPPED`).

**Known limitation:** after a successful reboot, the ALB target group continued reporting the instance as unhealthy (`Target.Timeout`) for roughly 60–90 seconds even though EC2/ASG considered it fully healthy — the health check's timing is tighter than the time Apache needs to fully restart and start responding. This resolved on its own, but a tighter fix would be tuning the health check's `unhealthy_threshold`/`interval`, or adding a short post-reboot grace period to the Lambda's logic.

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
├── main.tf                            # All AWS resources (VPC, subnets, ALB, ASG, RDS, CloudWatch, SNS)
├── variables.tf                       # Input variables (region, db password, alert email)
├── outputs.tf                         # Useful outputs (VPC ID, ALB DNS name, RDS endpoint)
├── provider.tf                        # Terraform + AWS provider configuration, S3 remote backend
├── .github/workflows/terraform-ci-cd.yml  # CI/CD pipeline: plan → tfsec → manual approval → apply
└── README.md
```

## Running This Project

**Locally:**
```bash
terraform init
terraform plan
terraform apply
```

You will be prompted for `db_password` and `alert_email` (both marked sensitive, not stored in the repo). Remote state is stored in S3 with DynamoDB locking, so this is safe to run alongside the CI/CD pipeline.

**Via the pipeline:** push a change to `main` (or open a pull request to preview the plan and security scan). After `plan` and the `tfsec` scan pass, approve the deployment in the `production` GitHub environment to apply.

**To tear down all resources:**

RDS has deletion protection enabled, so it must be disabled first:

```bash
aws rds modify-db-instance \
  --db-instance-identifier aws-self-healing-infra-db \
  --no-deletion-protection \
  --apply-immediately

terraform destroy
```

## Tech Stack

AWS (VPC, EC2, Auto Scaling, ALB, RDS, CloudWatch, SNS, IAM, OIDC, Lambda, DynamoDB, KMS, Athena) · Terraform (S3 + DynamoDB remote state) · GitHub Actions · tfsec · Amazon Linux 2023 · Python (boto3) · SQL

## Author

Lee Jinseo — [LinkedIn](https://www.linkedin.com/in/jinseo-lee-47bb0931a) · [Notion Build Log](https://jinseocloudportfolio.notion.site/AWS-Self-Healing-Infrastrcturture-Build-Log-383b9106b30380c489d7e84749425711?source=copy_link)
