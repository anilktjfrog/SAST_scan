# SAST Scan Automation Script

## Overview

`sast_scan.sh` is a Bash script that automates Static Application Security Testing (SAST) for codebases managed by Git or ClearCase. It identifies changed files, copies them to a temporary directory, runs a JFrog SAST scan, and generates a CSV report of the findings.

## Features

- Detects version control system (Git or ClearCase)
- Identifies changed files
- Copies changed files to a temporary directory
- Runs JFrog SAST scan on those files
- Generates CSV and table reports of SAST issues
- Keeps only the most recent reports and cleans up old/empty ones

## Prerequisites

- [JFrog CLI](https://jfrog.com/getcli/) installed and configured
- [`jq`](https://stedolan.github.io/jq/) installed (for JSON parsing)
- `rsync` and `awk` utilities available
- For table output: `column` utility (optional, for pretty-printing)
- Access to a Git or ClearCase repository

## Usage

```sh
./sast_scan.sh
```

The script will:

1. Detect your version control system.
2. Find changed files.
3. Copy them to a temporary directory.
4. Run a JFrog SAST scan.
5. Output results as a CSV and table in the `sast_reports` directory.

## Output

- **CSV Reports:** Saved in the `sast_reports` directory (e.g., `sast_report_YYYYMMDD_HHMMSS.csv`)
- **Raw JSON Output:** Also saved in `sast_reports`
- Only the five most recent CSV reports are kept; older and empty reports are deleted automatically.

## Notes

- The script sets `JF_SAST_DEFAULT_SCAN_MODE=file` and `JFROG_CLI_LOG_LEVEL=DEBUG` for the scan.
- For ClearCase support, the script uses `cleartool` commands (not fully tested).
- Temporary directories are cleaned up after the scan.

## Troubleshooting

- If you see an error about `jq` not found, install it with your package manager (e.g., `brew install jq` or `sudo yum install jq`).
- Ensure JFrog CLI is installed and authenticated.
