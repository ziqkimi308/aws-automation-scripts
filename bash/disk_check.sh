#!/bin/bash

set -euo pipefail

WARNING_THRESHOLD=70
CRITICAL_THRESHOLD=85
HOSTNAME=$(hostname)
LOG_FILE="/var/log/disk_check.log"

# log() here is included into report unlike ec2_audit because
# this script is meant to run automatically via cron.
# We need persistent log if any debug needed.

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_disk_usage() {
	log "Starting disk check on $HOSTNAME"

    local exit_code=0

	while IFS= read -r line; do
		local usage mount
		usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
		mount=$(echo "$line" | awk '{print $6}')

		if [[ "$usage" -ge "$CRITICAL_THRESHOLD" ]]; then
            log "CRITICAL: $mount is at ${usage}% — immediate action required"
            exit_code=2
        elif [[ "$usage" -ge "$WARNING_THRESHOLD" ]]; then
            log "WARNING: $mount is at ${usage}% — monitor closely"
            [[ "$exit_code" -lt 2 ]] && exit_code=1
        else
            log "OK: $mount is at ${usage}%"
        fi

	# '< <(command)' is called Process Substitution.

	done < <(df -h --output=pcent,target | tail -n +2 | grep -v "tmpfs\udev\loop")

	return "$exit_code"
}

# $? returns the last output

check_disk_usage
exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
    log "All disks healthy"
elif [[ "$exit_code" -eq 1 ]]; then
    log "WARNING state — review disk usage"
elif [[ "$exit_code" -eq 2 ]]; then
    log "CRITICAL state — take immediate action"
fi

exit "$exit_code"