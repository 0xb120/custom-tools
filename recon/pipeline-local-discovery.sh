#!/bin/bash
# ==============================================================================================
# Script Name: pipeline-local-discovery.sh
# Description: Full Recon Pipeline Worker for a Single Target Application.
#              Executes Passive OSINT -> Active Crawl (Smart Host) -> Mass Download sequentially.
#
# Usage:
#   ./pipeline-local-discovery.sh [target_workspace]
# ==============================================================================================

if [ "$#" -lt 1 ] || [ ! -d "$1" ]; then
    echo "[-] Error: Invalid application directory passed to pipeline." >&2
    exit 1
fi



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

echo " [✔] PIPELINE COMPLETD in $time FOR $APP_NAME" >&2
echo "---------------------------------------------------" >&2