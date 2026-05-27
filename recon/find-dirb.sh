#!/bin/bash
echo "$0: discover a brief exposed surface using directory and file fuzzing"

# Check if the first argument is a file
if [ -z "$1" ]; then
  echo "Error: First argument must exists."
  echo "Usage: $0 example.com [destination_directory]"
  exit 1
fi

# Set variables
id="$1"
timestamp="$(date +%s)"
target_dns="$1"
url=https://$target_dns

dest_dir="${2:-./$1}"

echo "Started bruteforcing directories for $url"

# Create destination directory if it doesn't exist
mkdir -p "$dest_dir"/scans
echo "[INFO] Working directory: $dest_dir"

echo "[CRAWL] Running feroxbuster in safe mode..."
feroxbuster --url $url \
-A \
--depth 3 \
--filter-status 404 \
--rate-limit 25 \
--threads 10 \
--wordlist /usr/share/seclists/Discovery/Web-Content/common.txt \
--output $dest_dir/scans/feroxbuster_"$timestamp".txt


# Time diff
end_time="$(date +%s)"
seconds="$(expr $end_time - $timestamp)"
time=""

if [[ "$seconds" -gt 59 ]]
then
    minutes=$(expr $seconds / 60)
    time="$minutes minutes"
else
    time="$seconds seconds"
fi

echo "Scan $id took $time"
echo "Remember to clean up tool output!"