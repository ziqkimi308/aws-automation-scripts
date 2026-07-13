#!/bin/bash

# errexit - exit script if any command failed.
# nounset - crash immediately if script tries to use variable that never defined.
# pipefail - if any part of pipe failed, all pipelines failed.
# named options needs -o flag, also can be write as "set -o errexit -o nounset -o pipefail".

set -euo pipefail

# ':-' is giving default value if variable is unset or empty.
# '$1' will be the first argument passed to that function.

REGION="${AWS_REGION:-ap-southeast-1}"
OUTPUT_FILE="/tmp/ec2_audit_$(date +%Y%m%d_%H%M%S).txt"
ALERT_THRESHOLD_DAYS=30

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Defensive programming - if one of the command not available, straight exit.
# var=(a b c) is indexed array.
# '!command' is reserved keyword for history expansion. Use '! command' for logical NOT.
# 'command -v' or 'which' are used to locate executable programs in $PATH.
# '&>/dev/null' - both stdout and stderr goes to /dev/null

check_dependencies() {
	local deps=("aws" "jq" "date")
	for dep in "${deps[@]}"; do
		if ! command -v "$dep" &>/dev/null;
		then
			log "ERROR: Required tool '$dep' is not installed."
			exit 1
		fi
	done
}

# 'launch_epoch' first condition is for Linux, then MacOS.
# '-d' to use custom date
# While -d is 'find and use custom date', -j is 'do not use system's clock'
# so it has no other way except looking at -f and the argument after it.

get_instance_age_days() {
	local launch_time="$1"
	local launch_epoch
	launch_epoch=$(date -d "$launch_time" +%s 2>/dev/null ||
	date -j -f "%Y-%m-%dT%H:%M:%S" "$launch_time" +%s)
	local now_epoch
	now_epoch=$(date +%s)
	echo $(( (now_epoch - launch_epoch) / 86400 ))
}

audit_ec2_instances() {
	log "Starting EC2 audit for region: $REGION"
	echo "============================================" | tee "$OUTPUT_FILE"
	echo "EC2 AUDIT REPORT - $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$OUTPUT_FILE"
	echo "Region: $REGION" | tee -a "$OUTPUT_FILE"
	echo "============================================" | tee -a "$OUTPUT_FILE"

	# '?' if filter operator in JMESPath.
	# jq = cli JSON processor. Like sed or awk but for JSON.
	# 'jq -r' = raw output. Produce without JSON quotes.
	# '.[][] | @base64' the JSON outputs is flattened into one stream of sequential objects.
	# Then, converted into Base64 to prevent newline or special characters that later will break the Bash's read loop.

	local instances
	instances=$(aws ec2 describe-instances \
		--region "$REGION" \
		--query 'Reservations[*].Instances[*].{
			ID:InstanceId,
			Type:InstanceType,
			State:State.Name,
			LaunchTime:LaunchTime,
			PublicIP:PublicIpAddress,
			PrivateIP:PrivateIpAddress,
			Name:Tags[?Key==`Name`][0].Value
		}' \
		--output json | jq -r '.[][] | @base64'
	)

	# '-z' checks if length of string = 0

	if [[ -z "$instances" ]]; then
		log "No instances found in $REGION"
		return
	fi

	local total=0
    local running=0
    local stopped=0
    local old_instances=()

	# Earlier we produced single massive string containing all instance data.
	# This process is to split that data into individual records.
	# '-r' = raw - prevents backlash characters from being interpreted as escape sequences.

	while IFS= read -r instance; do
		local decoded
		decoded=$(echo "$instance" | base64 --decode)

		# '//' is null coalescing operator

		local id state launch_time name instance_type public_ip
        id=$(echo "$decoded" | jq -r '.ID')
        state=$(echo "$decoded" | jq -r '.State')
        launch_time=$(echo "$decoded" | jq -r '.LaunchTime')
        name=$(echo "$decoded" | jq -r '.Name // "unnamed"')
        instance_type=$(echo "$decoded" | jq -r '.Type')
        public_ip=$(echo "$decoded" | jq -r '.PublicIP // "none"')

		local age_days
        age_days=$(get_instance_age_days "$launch_time")

		total=$((total + 1))
        [[ "$state" == "running" ]] && running=$((running + 1))
        [[ "$state" == "stopped" ]] && stopped=$((stopped + 1))
		[[ "$age_days" -gt "$ALERT_THRESHOLD_DAYS" ]] && old_instances+=("$name ($id)")

		# string formatting to offset the output from left

		printf "%-20s %-15s %-10s %-10s %-16s %s days old\n" \
            "$name" "$id" "$instance_type" "$state" "$public_ip" "$age_days" | tee -a "$OUTPUT_FILE"

	done <<< "$instances"

	echo "--------------------------------------------" | tee -a "$OUTPUT_FILE"
    echo "Total: $total | Running: $running | Stopped: $stopped" | tee -a "$OUTPUT_FILE"

	if [[ ${#old_instances[@]} -gt 0 ]]; then
		echo "" | tee -a "$OUTPUT_FILE"
        echo "WARNING: Instances older than ${ALERT_THRESHOLD_DAYS} days:" | tee -a "$OUTPUT_FILE"
		for inst in "${old_instances[@]}"; do
            echo "  - $inst" | tee -a "$OUTPUT_FILE"
        done
	fi

	log "Audit complete. Report saved to $OUTPUT_FILE"
}

check_dependencies
audit_ec2_instances


# Example Output on Screen:
# [2026-07-13 14:30:22] Starting EC2 audit for region: ap-southeast-1
# ============================================
# EC2 AUDIT REPORT - 2026-07-13 14:30:22
# Region: ap-southeast-1
# ============================================
# web-server-prod      i-0abc123def456   t2.micro   running    54.123.45.67       3 days old
# db-server-backup     i-xyz7890         t3.large   stopped    none               45 days old
# cache-node           i-def456ghi789    t2.micro   running    none               12 days old
# --------------------------------------------
# Total: 3 | Running: 2 | Stopped: 1

# WARNING: Instances older than 30 days:
#   - db-server-backup (i-xyz7890)
# [2026-07-13 14:30:22] Audit complete. Report saved to /tmp/ec2_audit_20260713_143022.txt

# Example Outputs on Report:
# ============================================
# EC2 AUDIT REPORT - 2026-07-13 14:30:22
# Region: ap-southeast-1
# ============================================
# web-server-prod      i-0abc123def456   t2.micro   running    54.123.45.67       3 days old
# db-server-backup     i-xyz7890         t3.large   stopped    none               45 days old
# cache-node           i-def456ghi789    t2.micro   running    none               12 days old
# --------------------------------------------
# Total: 3 | Running: 2 | Stopped: 1

# WARNING: Instances older than 30 days:
#   - db-server-backup (i-xyz7890)