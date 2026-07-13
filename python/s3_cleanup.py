import boto3
import os
import logging
from datetime import datetime, timezone, timedelta
from dotenv import load_dotenv

load_dotenv()

REGION = os.getenv("AWS_REGION", "ap-southeast-1")
BUCKET_NAME = os.getenv("S3_BUCKET_NAME")
RETENTION_DAYS = int(os.getenv("RETENTION_DAYS", "30"))
DRY_RUN = os.getenv("DRY_RUN", "true").lower() == "true"

logging.basicConfig(
	level=logging.INFO,
	format="%(asctime)s [%(levelname)s] %(message)s",
	datefmt="%Y-%m-%d %H:%M:%S"
)

# logger has singleton pattern
# it returns the same logger object if called twice in same script.

logger = logging.getLogger(__name__)

def get_s3_client():
	"""
	Create low-level client (s3) as entry point to aws service.
	"""
	return boto3.client("s3", region_name=REGION)

def get_all_objects(client, bucket):
	"""
	Access an s3 bucket and fetch all objects.
	"""
	objects = []
	paginator = client.get_paginator("list_objects_v2")

	for page in paginator.paginate(Bucket=bucket):
		if "Contents" not in page:
			continue
		objects.extend(page["Contents"])
	
	return objects

def identify_old_objects(objects, retention_days):
	"""
	Identifies objects older than retention days.
	"""
	cutoff = datetime.now(timezone.utc) - timedelta(days=retention_days)
	old_objects = []

	for obj in objects:
		last_modified = obj["LastModified"]
		if last_modified < cutoff:
			old_objects.append({
                "key": obj["Key"],
                "last_modified": last_modified,
                "size_kb": round(obj["Size"] / 1024, 2),
                "age_days": (datetime.now(timezone.utc) - last_modified).days
            })
	
	return old_objects

def delete_objects(client, bucket, objects):
	"""
	Delete operation s3 objects.
	"""
	if not objects:
		logger.info("No objects to delete")
		return 0
	
	delete_payload = {
        "Objects": [{"Key": obj["key"]} for obj in objects],
        "Quiet": False
    }

	response = client.delete_objects(Bucket=bucket, Delete=delete_payload)

	deleted_count = len(response.get("Deleted", []))
	errors = response.get("Errors", [])

	if errors:
		for error in errors:
			logger.error(f"Failed to delete {error['Key']}: {error['Message']}")
			
	return deleted_count

def run_cleanup():
	"""
	The main function where execution happens.
	"""
	if not BUCKET_NAME:
		logger.error("S3_BUCKET_NAME environment variable is not set")
		raise ValueError("S3_BUCKET_NAME is required")
	
	logger.info(f"Starting S3 cleanup for bucket: {BUCKET_NAME}")
	logger.info(f"Retention policy: {RETENTION_DAYS} days | Dry run: {DRY_RUN}")
	
	client = get_s3_client()

	logger.info("Fetching all objects (paginated)...")
	all_objects = get_all_objects(client, BUCKET_NAME)
	logger.info(f"Found {len(all_objects)} total objects")

	old_objects = identify_old_objects(all_objects, RETENTION_DAYS)
	logger.info(f"Found {len(old_objects)} objects older than {RETENTION_DAYS} days")
	
	total_size_kb = sum(obj["size_kb"] for obj in old_objects)
	logger.info(f"Total size to reclaim: {total_size_kb:.2f} KB")

	for obj in old_objects:
		logger.info(
            f"  {'[DRY RUN] Would delete' if DRY_RUN else 'Deleting'}: "
            f"{obj['key']} | {obj['age_days']} days old | {obj['size_kb']} KB"
        )

	if DRY_RUN:
		logger.info("Dry run complete — no objects deleted. Set DRY_RUN=false to execute.")
		
		return

	deleted = delete_objects(client, BUCKET_NAME, old_objects)
	logger.info(f"Cleanup complete — deleted {deleted} objects, reclaimed {total_size_kb:.2f} KB")

if __name__ == "__main__":
    run_cleanup()

"""
Example Outputs:

2026-07-13 14:00:00 [INFO] Starting S3 cleanup for bucket: my-devops-bucket-john
2026-07-13 14:00:00 [INFO] Retention policy: 30 days | Dry run: True
2026-07-13 14:00:00 [INFO] Fetching all objects (paginated)...
2026-07-13 14:00:01 [INFO] Found 150 total objects
2026-07-13 14:00:01 [INFO] Found 4 objects older than 30 days
2026-07-13 14:00:01 [INFO] Total size to reclaim: 1024.45 KB
2026-07-13 14:00:01 [INFO]   [DRY RUN] Would delete: old-backup-2025-12-01.log | 224 days old | 450.20 KB
2026-07-13 14:00:01 [INFO]   [DRY RUN] Would delete: temp-session-2026-05-15.csv | 59 days old | 312.10 KB
2026-07-13 14:00:01 [INFO]   [DRY RUN] Would delete: unused-ami-image.png | 31 days old | 150.15 KB
2026-07-13 14:00:01 [INFO]   [DRY RUN] Would delete: debug-dump-2026-04-22.txt | 82 days old | 112.00 KB
2026-07-13 14:00:01 [INFO] Dry run complete — no objects deleted. Set DRY_RUN=false to execute.
"""