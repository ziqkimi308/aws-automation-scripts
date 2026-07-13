# Automate AWS Tasks with Bash, Python, and boto3

> — A production-grade automation suite to audit EC2, clean up S3 objects, monitor disk space, and schedule everything with cron.

## Overview
This repository contains the automation scripts built. It demonstrates how to combine Bash (for quick CLI orchestration) and Python + boto3 (for complex SDK logic) into a unified, cron-scheduled toolkit.

## Project Structure
```
aws-automation-scripts/
├── bash/
│   ├── ec2_audit.sh          # EC2 inventory + age alerting
│   └── disk_check.sh         # Disk usage monitor (Nagios exit codes)
├── python/
│   ├── s3_cleanup.py         # S3 lifecycle management (pagination + dry-run)
│   ├── resource_report.py    # Daily multi-service dashboard
│   └── requirements.txt      # boto3, tabulate, python-dotenv
├── scheduler/
│   └── setup_cron.sh         # Idempotent cron job installer
└── README.md
```

## Project Summary
This project implements a production-grade automation toolkit for AWS, designed to run unattended on an EC2 instance. It bridges Bash scripting (for fast, dependency-light CLI orchestration) with Python and boto3 (for complex API pagination and multi-service data aggregation).

A local development environment is set up with a Python virtual environment and a `.env` file for configuration (region, S3 bucket, retention days, and dry-run mode). Two Bash scripts are written: `ec2_audit.sh` queries the AWS CLI and uses `jq` and Base64 encoding to safely parse EC2 data, calculating instance ages and flagging anything older than 30 days; `disk_check.sh` monitors filesystem usage and exits with Nagios-compatible codes (0/1/2). Two Python scripts are then built: `s3_cleanup.py` uses boto3 paginators to fetch all S3 objects, applies a retention cutoff, and performs batch deletions—with dry-run safety enabled by default; `resource_report.py` uses a single boto3 session to generate daily snapshots of EC2 inventory, S3 storage totals, and a security audit flagging any inbound `0.0.0.0/0` security group rules.

A cron scheduler (`setup_cron.sh`) idempotently installs four jobs: the resource report and EC2 audit run daily, disk checks run every 30 minutes, and the S3 cleanup runs weekly with destructive mode enabled. All stdout and stderr are appended to dedicated log files in `/var/log/aws-automation/`, providing a complete audit trail. The final result is a fully headless, scheduled automation suite that continuously audits fleet health, enforces S3 lifecycle policies, and surfaces security risks without manual intervention.

## Challenges Encountered & Solutions

### 1. Bash Safety & Global Scope
**Issue:** Understanding why `set -euo pipefail` and `local` are non-negotiable in production.
**Fix:** Implemented rigorous scoping. `local` protects variables inside functions (unlike Python/JS, Bash defaults to **global** scope). `pipefail` ensures a failure in any part of a pipeline (e.g., `aws ... | jq`) halts the script.

### 2. The "Subshell Trap" (Pipes vs Here-Strings)
**Issue:** Using `echo "$instances" | while read` caused counters (`total`, `running`) to reset to `0` after the loop ended because the pipe creates a subshell.
**Fix:** Switched to `while read ...; done <<< "$instances"` (Here-String). This keeps the loop running in the **current shell**, preserving variable changes.

### 3. Parsing JSON in Bash (The Base64 Hack)
**Issue:** EC2 `Name` tags can contain spaces, newlines, or special characters that break Bash's `read` loop.
**Fix:** Piped the AWS CLI output through `jq -r '.[][] | @base64'`. This encodes the entire JSON object for each instance into a single, safe line. Inside the loop, `base64 --decode` restores the data without corruption. This prevents the loop from splitting on internal newlines.

### 4. Cross-Platform Date Compatibility (Linux vs macOS)
**Issue:** The script calculates instance age using `date -d` (Linux/GNU) which fails on macOS.
**Fix:** Implemented a fallback hack: `date -d ... 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" ...`. The `||` operator gracefully switches to the macOS BSD `date` syntax when the Linux version fails.

### 5. Python `boto3` Pagination
**Issue:** S3 `list_objects_v2` only returns 1,000 objects per API call. Without handling pagination, objects beyond the first 1,000 would be silently ignored.
**Fix:** Used `client.get_paginator("list_objects_v2")`. This automatically loops through all pages and extends the `objects` list, ensuring **every** object is evaluated for deletion, regardless of bucket size.

### 6. Dry-Run Safety Pattern
**Issue:** The S3 cleanup script is destructive.
**Fix:** Wrapped the deletion logic in an `if DRY_RUN:` block. By default, `DRY_RUN=true`, meaning the script only logs what it *would* delete. Users must explicitly set `DRY_RUN=false` to execute deletions—a crucial safety net for production automation.

### 7. Cron Scheduling & Idempotence
**Issue:** Running `setup_cron.sh` multiple times would duplicate cron jobs.
**Fix:** The script dumps the current crontab to a temp file, uses `grep -qF` to check for exact matches, and only appends missing jobs. It uses `mktemp` to safely edit the crontab without corrupting the live system.

### 8. Inbound vs. Outbound Security Groups
**Issue:** Understanding why `resource_report.py` only flags security groups with `0.0.0.0/0`.
**Fix:** The script checks `IpPermissions` (Inbound). Inbound `0.0.0.0/0` is a critical security risk (exposing ports to the internet). Outbound `0.0.0.0/0` is generally safe and required for instances to reach the internet for patches/updates, so it is ignored by the audit.

## Key Technical Discussions

### Why `next()` with a Generator?
In `resource_report.py`, we use `next((tag["Value"] for tag in ... if tag["Key"] == "Name"), "unnamed")`. 
**Why not just a `for` loop?** This line is a "first-match finder." It executes the generator just long enough to find the `Name` tag. If no match exists, it returns `"unnamed"`. It is faster than building a temporary list and is standard Pythonic boilerplate for extracting optional tags.

### Bash vs Python (The Overlap)
Both `ec2_audit.sh` and `resource_report.py` query EC2.
**Why the overlap?** 
- `ec2_audit.sh` teaches **portable, dependency-light** scripting (great for bootstrapping).
- `resource_report.py` teaches **service aggregation, structured tables (`tabulate`), and reusable boto3 sessions**. 
This project is a bootcamp for both tools, allowing you to choose the right tool based on the environment (Bash for quick CLI, Python for complex data).

### Virtual Environment Placement (`venv/`)
**Discussion:** Placing `venv/` in the project root feels weird for a polyglot repo (since `bash/` exists).
**Decision:** Kept it at the root per the guide's path assumptions in `setup_cron.sh`. This keeps the cron scheduler pointing to `/home/ubuntu/.../venv/bin/python` without complex relative paths.

## Cleanup
- Remove cron jobs: `crontab -r`
- Terminate the EC2 instance.
- Empty and delete the test S3 bucket.
