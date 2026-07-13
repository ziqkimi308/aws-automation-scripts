import boto3
import os
import logging
from datetime import datetime, timezone
from tabulate import tabulate
from dotenv import load_dotenv

load_dotenv()

REGION = os.getenv("AWS_REGION", "ap-southeast-1")

logging.basicConfig(
	level=logging.INFO,
	format="%(asctime)s [%(levelname)s] %(message)s",
	datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger(__name__)

def get_ec2_summary(session):
	"""
	Return EC2 summary.
	"""
	ec2 = session.client("ec2", region_name=REGION)
	response = ec2.describe_instances()

	instances = []
	for reservation in response["Reservations"]:
		for inst in reservation["Instances"]:
			
			# next() takes generator expression, runs it until first match,
			# if not found, it provides fallback value

			name = next(
				(tag["Value"] for tag in inst.get("Tags", []) if tag["Key"] == "Name"),
				"unnamed"
			)
			launch_time = inst["LaunchTime"]
			age_days = (datetime.now(timezone.utc) - launch_time).days

			instances.append([
				name,
				inst["InstanceId"],
				inst["InstanceType"],
				inst["State"]["Name"],
				inst.get("PublicIpAddress", "none"),
				f"{age_days} days"
			])

	return instances

def get_s3_summary(session):
	"""
	Return s3 summary.
	"""
	s3 = session.client("s3", region_name=REGION)
	buckets_response = s3.list_buckets()

	summary = []
	for bucket in buckets_response["Buckets"]:
		name = bucket["Name"]
		try:
			paginator = s3.get_paginator("list_objects_v2")
			total_size = 0
			total_objects = 0

			for page in paginator.paginate(Bucket=name):
				for obj in page.get("Contents", []):
					total_objects += 1
					total_size += obj["Size"]
			
			summary.append([
                name,
                total_objects,
                f"{round(total_size / (1024 * 1024), 2)} MB"
            ])

		except Exception as e:
			summary.append([name, "error", str(e)])
			
	return summary

def get_security_group_summary(session):
	"""
	Return security groups with 0.0.0.0/0 rules.
	"""
	ec2 = session.client("ec2", region_name=REGION)
	response = ec2.describe_security_groups()

	# IpPermissions = inbound
	# IpPermissionsEgress = outbound
	
	risky = []
	for sg in response["SecurityGroups"]:
		for rule in sg.get("IpPermissions", []):
			for ip_range in rule.get("IpRanges", []):
				if ip_range.get("CidrIp") == "0.0.0.0/0":
					from_port = rule.get("FromPort", "all")
					to_port = rule.get("ToPort", "all")
					risky.append([
                        sg["GroupName"],
                        sg["GroupId"],
                        f"{from_port}-{to_port}",
                        "0.0.0.0/0 — open to internet"
                    ])
					
	return risky

def generate_report():
	"""
	The main function that executes all.
	"""
	logger.info("Generating AWS resource report...")
	session = boto3.Session(region_name=REGION)
	
	print("\n" + "=" * 60)
	print(f"AWS RESOURCE REPORT — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
	print(f"Region: {REGION}")
	print("=" * 60)

	print("\n[ EC2 INSTANCES ]")
	ec2_data = get_ec2_summary(session)
	if ec2_data:
		print(tabulate(
            ec2_data,
            headers=["Name", "Instance ID", "Type", "State", "Public IP", "Age"],
            tablefmt="grid"
        ))
	else:
		print("No EC2 instances found")

	print("\n[ S3 BUCKETS ]")
	s3_data = get_s3_summary(session)
	if s3_data:
		print(tabulate(
            s3_data,
            headers=["Bucket Name", "Objects", "Total Size"],
            tablefmt="grid"
        ))
	else:
		print("No S3 buckets found")

	print("\n[ SECURITY RISK — OPEN SECURITY GROUPS ]")
	sg_data = get_security_group_summary(session)
	if sg_data:
		print(tabulate(
            sg_data,
            headers=["SG Name", "SG ID", "Port Range", "Risk"],
            tablefmt="grid"
        ))
	else:
		print("No security groups open to 0.0.0.0/0 — good")

	print("\n" + "=" * 60)
	logger.info("Report complete")
