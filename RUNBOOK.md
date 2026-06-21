# Operations Runbook — Self-Healing AWS Infrastructure

This runbook documents incident response procedures for the alarms and monitoring
configured in this project, plus troubleshooting notes from real incidents
encountered while building and operating the infrastructure.

Related: [CloudWatch Dashboard](https://ap-southeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-southeast-1#dashboards:name=aws-self-healing-infra-dashboard)

---

## 1. Alarm Response Procedures

### 1.1 `aws-self-healing-infra-unhealthy-hosts`

| Field | Detail |
|---|---|
| **Metric** | `UnHealthyHostCount` (ALB Target Group) |
| **Condition** | ≥ 1 unhealthy target for 2 consecutive periods (2 min) |
| **Notification** | SNS → email + Lambda auto-remediation |
| **Severity** | High — directly impacts availability |

**What it means:** One or more EC2 instances behind the ALB are failing health
checks. The ASG/Lambda auto-remediation pipeline should already be acting on
this, but manual verification confirms it's working as intended.

**1st-line checks:**
```bash
# Confirm current unhealthy target count
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  --region ap-southeast-1

# Check ASG activity — is a replacement instance already launching?
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name aws-self-healing-infra-asg \
  --region ap-southeast-1 --max-records 5
```

**Action:**
1. If ASG is already replacing the instance → monitor, no action needed.
2. If not replacing → check Lambda logs for remediation failures:
```bash
   aws logs tail /aws/lambda/aws-self-healing-infra-auto-remediation \
     --region ap-southeast-1 --since 10m
```
3. Check DynamoDB cooldown table — remediation may be intentionally
   suppressed to prevent thrashing:
```bash
   aws dynamodb scan --table-name aws-self-healing-infra-remediation-cooldown \
     --region ap-southeast-1
```
4. If cooldown is blocking a legitimate new failure, manually terminate the
   unhealthy instance to force ASG replacement:
```bash
   aws ec2 terminate-instances --instance-ids <instance-id> --region ap-southeast-1
```

**Escalation:** If 2+ replacement cycles fail back-to-back, stop auto-remediation
(disable the SNS→Lambda subscription) and investigate the AMI / launch template
for a systemic issue (e.g. bad user-data script) before further replacements
make things worse.

**Recovery:** OK-state notification fires automatically once `UnHealthyHostCount`
returns to 0 for the evaluation period. No manual close-out needed.

---

### 1.2 `aws-self-healing-infra-high-cpu`

| Field | Detail |
|---|---|
| **Metric** | `CPUUtilization` (ASG average) |
| **Condition** | > 70% average for 2 consecutive periods (2 min) |
| **Notification** | SNS → email |
| **Severity** | Medium — early warning, not yet an outage |

**What it means:** Fleet-wide CPU load is elevated. This is a leading
indicator, not yet a failure — health checks may still be passing.

**1st-line checks:**
```bash
# Per-instance CPU breakdown
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions Name=AutoScalingGroupName,Value=aws-self-healing-infra-asg \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 --statistics Average Maximum --region ap-southeast-1
```

**Action:**
1. Check if load is from legitimate traffic (Dashboard → ALB Request Count
   widget) vs. a runaway process.
2. If legitimate traffic growth → consider raising ASG desired capacity or
   adjusting the threshold; this is a capacity-planning signal.
3. If a single instance is spiking disproportionately → SSH in (or SSM
   Session Manager) and check `top` / `htop` for the offending process.

**Escalation:** If CPU stays >70% for >15 min without traffic correlation,
treat as a potential resource leak or runaway process — isolate the instance
from the target group before debugging further.

---

## 2. Incident Case Study: RDS Recreation — Free Tier Constraints (2026-06-21)

**Context:** While provisioning the CloudWatch Dashboard, `terraform plan`
revealed the RDS instance had been deleted in a prior session (confirmed via
CloudTrail `DeleteDBInstance` events) and was no longer tracked in state.
Recreating it surfaced two AWS Free Tier restrictions not caught during
initial code review.

**Symptom 1:**
