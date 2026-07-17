#!/bin/bash
set -euo pipefail

# Archive a report file with timestamp before it's overwritten
# Usage: archive_report.sh <file_path>

if [[ $# -eq 0 ]]; then
  echo "Error: file path argument required" >&2
  exit 1
fi

file_path="$1"

# If file doesn't exist or is empty, exit successfully (no content to archive)
if [[ ! -f "$file_path" ]] || [[ ! -s "$file_path" ]]; then
  exit 0
fi

# Get directory and filename
dir=$(dirname "$file_path")
filename=$(basename "$file_path")
name_no_ext="${filename%.*}"

# Create archive directory if it doesn't exist
archive_dir="$dir/archive"
mkdir -p "$archive_dir"

# Get current timestamp in YYYYMMDD_HHMMSS format
timestamp=$(date +%Y%m%d_%H%M%S)

# Create archive path
archive_path="$archive_dir/${name_no_ext}_${timestamp}.yaml"

# Copy the file to archive
cp "$file_path" "$archive_path"

# Output the archive path to stdout
echo "$archive_path"
