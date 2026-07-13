#!/bin/bash

set -euo pipefail

SCRIPTS_DIR="/home/ubuntu/aws-automation-scripts"
VENV_PYTHON="$SCRIPTS_DIR/venv/bin/python3"
LOG_DIR="/var/log/aws-automation"
CRON_USER="ubuntu"

sudo mkdir -p "$LOG_DIR"
sudo chown "$CRON_USER:$CRON_USER" "$LOG_DIR"

CRON_JOBS=(
    "0 8 * * * $VENV_PYTHON $SCRIPTS_DIR/python/resource_report.py >> $LOG_DIR/resource_report.log 2>&1"
    "0 9 * * * bash $SCRIPTS_DIR/bash/ec2_audit.sh >> $LOG_DIR/ec2_audit.log 2>&1"
    "*/30 * * * * bash $SCRIPTS_DIR/bash/disk_check.sh >> $LOG_DIR/disk_check.log 2>&1"
    "0 2 * * 0 DRY_RUN=false S3_BUCKET_NAME=my-devops-bucket $VENV_PYTHON $SCRIPTS_DIR/python/s3_cleanup.py >> $LOG_DIR/s3_cleanup.log 2>&1"
)

TEMP_CRON=$(mktemp)
crontab -l -u "$CRON_USER" 2>/dev/null > "$TEMP_CRON" || true

for job in "${CRON_JOBS[@]}"; do
    if ! grep -qF "$job" "$TEMP_CRON"; then
        echo "$job" >> "$TEMP_CRON"
        echo "Added: $job"
    else
        echo "Already exists: $job"
    fi
done

crontab -u "$CRON_USER" "$TEMP_CRON"
rm "$TEMP_CRON"

echo "Cron jobs installed. Current crontab:"
crontab -l -u "$CRON_USER"