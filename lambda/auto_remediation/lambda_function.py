import json
import boto3
import os
from datetime import datetime, timezone

ec2 = boto3.client('ec2')
elbv2 = boto3.client('elbv2')
dynamodb = boto3.resource('dynamodb')
sns = boto3.client('sns')

COOLDOWN_TABLE = os.environ['COOLDOWN_TABLE']
TARGET_GROUP_ARN = os.environ['TARGET_GROUP_ARN']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
COOLDOWN_MINUTES = int(os.environ.get('COOLDOWN_MINUTES', '10'))

table = dynamodb.Table(COOLDOWN_TABLE)


def lambda_handler(event, context):
    record = event['Records'][0]['Sns']
    message = record['Message']

    try:
        alarm_data = json.loads(message)
    except (json.JSONDecodeError, TypeError):
        print("Not a CloudWatch alarm message, skipping.")
        return

    # Guard: only react to actual CloudWatch alarm notifications,
    # not our own follow-up notifications published back to the same topic.
    if 'AlarmName' not in alarm_data:
        print("Message has no AlarmName field, skipping (likely our own notification).")
        return

    if alarm_data.get('NewStateValue') != 'ALARM':
        print(f"Alarm state is {alarm_data.get('NewStateValue')}, not ALARM. Skipping.")
        return

    unhealthy_instance_ids = get_unhealthy_instance_ids()

    if not unhealthy_instance_ids:
        print("No unhealthy instances found in target group. Nothing to do.")
        return

    results = []
    for instance_id in unhealthy_instance_ids:
        if is_in_cooldown(instance_id):
            results.append(f"{instance_id}: SKIPPED (cooldown active)")
            continue

        try:
            reboot_instance(instance_id)
            record_remediation(instance_id)
            results.append(f"{instance_id}: REBOOTED")
        except Exception as e:
            results.append(f"{instance_id}: FAILED ({str(e)})")

    notify_result(results)


def get_unhealthy_instance_ids():
    response = elbv2.describe_target_health(TargetGroupArn=TARGET_GROUP_ARN)
    unhealthy = []
    for target in response['TargetHealthDescriptions']:
        state = target['TargetHealth']['State']
        if state in ('unhealthy', 'unused', 'draining'):
            unhealthy.append(target['Target']['Id'])
    return unhealthy


def is_in_cooldown(instance_id):
    response = table.get_item(Key={'instance_id': instance_id})
    item = response.get('Item')
    if not item:
        return False

    last_remediation = datetime.fromisoformat(item['last_remediation_time'])
    elapsed_minutes = (datetime.now(timezone.utc) - last_remediation).total_seconds() / 60
    return elapsed_minutes < COOLDOWN_MINUTES


def reboot_instance(instance_id):
    print(f"Rebooting instance {instance_id}")
    ec2.reboot_instances(InstanceIds=[instance_id])


def record_remediation(instance_id):
    table.put_item(Item={
        'instance_id': instance_id,
        'last_remediation_time': datetime.now(timezone.utc).isoformat()
    })


def notify_result(results):
    message = "Auto-remediation result:\n" + "\n".join(results)
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="[Self-Healing Infra] Auto-Remediation Executed",
        Message=message
    )
    print(message)
