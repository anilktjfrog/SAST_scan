#!/bin/bash

###############################################################
#                  SAST SCAN AUTOMATION SCRIPT                #
# ----------------------------------------------------------- #
# This script automates the following steps:                  #
#  1. Detects the version control system (Git or ClearCase)   #
#  2. Gets a list of changed files                            #
#  3. Copies changed files to a temporary directory           #
#  4. Runs a JFrog SAST scan on those files                  #
#  5. Generates a CSV report and displays results             #
#  6. Keeps only the most recent reports, cleans up old/empty #
#                                                             #
# Usage: ./sast_scan.sh                                       #
###############################################################

# --- Configuration ---

# Set the desired number of threads for the JFrog scan.
# This is cross-platform for Linux and macOS.
if command -v nproc >/dev/null 2>&1; then
    NUM_CPUS=$(nproc)
elif command -v sysctl >/dev/null 2>&1; then
    NUM_CPUS=$(sysctl -n hw.ncpu)
else
    NUM_CPUS=4 # Default fallback
fi
if [ "$NUM_CPUS" -gt 4 ]; then
    SCAN_THREADS=$NUM_CPUS
else
    SCAN_THREADS=4
fi

# Set JFrog CLI environment variables for the scan
echo "Setting JF_SAST_DEFAULT_SCAN_MODE to 'file' and JFROG_CLI_LOG_LEVEL to 'DEBUG'"
export JF_SAST_DEFAULT_SCAN_MODE=file
export JFROG_CLI_LOG_LEVEL=DEBUG

# --- Functions ---

# Function to detect the version control system
detect_vcs() {
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "git"
    elif cleartool ls &>/dev/null; then
        echo "clearcase"
    else
        echo "unknown"
    fi
}

# Function to get changed files from a Git repository
get_git_changes() {
    git status --porcelain | awk '{print $2}'
}

# Function to get changed files from a ClearCase repository
# NOT TESTED
get_clearcase_changes() {
    cleartool ls -short | while read -r line; do
        cleartool describe "$line" | grep "CHECKEDOUT" &>/dev/null
        if [ $? -eq 0 ]; then
            echo "$line"
        fi
    done
}

# Function to run the SAST scan
run_sast_scan() {

    local target_dir=$1
    # Parse SAST issues and output as CSV or table
    local sast_dir="$(pwd)/sast_reports"
    mkdir -p "$sast_dir"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local csv_file="$sast_dir/sast_report_${timestamp}.csv"

    echo -e "\n========================================="
    echo " Running JFrog SAST scan on changed files in: $target_dir"
    echo " Using $SCAN_THREADS threads."
    echo "========================================="
    local current_dir
    current_dir=$(pwd)

    echo "Current directory: $current_dir"
    echo "Changing to target directory to perform SAST scan: $target_dir"
    echo "-----------------------------------------"
    cd "$target_dir"


    local scan_output_file="$sast_dir/sast_raw_${timestamp}.json"
    scan_command="jf audit --sast=true --threads=$SCAN_THREADS --format simple-json > \"$scan_output_file\""
    echo "Executing: $scan_command"
    echo "-----------------------------------------"
    # Use eval to execute the command with redirection
    eval $scan_command
    echo "Raw JSON scan output saved to: $scan_output_file"
    echo "-----------------------------------------"

    # No need to store output in a variable; use the file directly for further processing

    echo "Changing back to original directory: $current_dir"
    cd "$current_dir"

    # Use jq to parse JSON output
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required to parse JSON output. Please install jq."
        return 1
    fi


    # Extract SAST issues
    local sast_count

    # Remove control characters before jq count as well
    sast_count=$(cat "$scan_output_file" | tr -d '\000-\037' | jq '.sast | length')
    if [ -z "$sast_count" ] || [ "$sast_count" = "null" ] || [ "$sast_count" -eq 0 ]; then
        echo "No SAST issues found."
        return 0
    fi

    # Prepare CSV header
    echo "-----------------------------------------"
    echo "Total SAST issues found: $sast_count"
    local header="severity,file,line,column,finding"
    echo "$header" > "$csv_file"
    echo "-----------------------------------------"
    echo "SAST Report CSV File: $csv_file"
    echo "-----------------------------------------"

    # Write each SAST finding as a CSV row, using only top-level startLine/startColumn

    cat "$scan_output_file" | tr -d '\000-\037' | jq -r '
        .sast[] | [
            (.severity // ""),
            (.file // ""),
            (.startLine // ""),
            (.startColumn // ""),
            ((.finding // "")
                | gsub("\n"; " ")
                | gsub("\r"; " ")
                | gsub("\""; "'\''")
            )
        ] | @csv
    ' >> "$csv_file"

    # Remove CSV file if empty (only header)
    if [ $(wc -l < "$csv_file") -le 1 ]; then
        rm -f "$csv_file"
        echo "No SAST codeFlow details found."
        return 0
    fi

    # If format=table, display as table
    echo -e "\n========== SAST Scan Results =========="
    echo -e "\nSAST issues (Table Format):"
    if command -v column >/dev/null 2>&1; then
        column -t -s, "$csv_file"
    else
        echo "Error: column command not found. Displaying raw CSV output."
        cat "$csv_file"
    fi

    echo "========================================="
    echo -e "\nSAST issues (CSV Format):"
    cat "$csv_file"
    echo "========================================="

    # Keep only 5 most recent CSVs, delete older and empty ones
    local csv_files
    latest_count=5
    echo -e "\n-----------------------------------------"
    echo "Keeping only the $latest_count most recent CSV reports."
    csv_files=($(ls -1t "$sast_dir"/*.csv 2>/dev/null))
    local count=${#csv_files[@]}
    if [ "$count" -gt "$latest_count" ]; then
        echo "Total CSV reports: $count. Deleting older reports..."
        for ((i=latest_count; i<${count}; i++)); do
            echo "Deleting old CSV: ${csv_files[$i]} as only keeping $latest_count most recent reports."
            rm -f "${csv_files[$i]}"
        done
    fi
    # Remove any empty CSVs (only header)
    for f in "$sast_dir"/*.csv; do
        if [ -f "$f" ] && [ $(wc -l < "$f") -le 1 ]; then
            echo "Checking if file is empty: $f and removing file if empty."
            rm -f "$f"
        fi
    done
}

# --- Main Execution ---

main() {

    echo ""
    echo "###############################################################"
    echo "#                  SAST SCAN AUTOMATION SCRIPT                #"
    echo "# ----------------------------------------------------------- #"
    echo "# This script automates the following steps:                  #"
    echo "#  1. Detects the version control system (Git or ClearCase)   #"
    echo "#  2. Gets a list of changed files                            #"
    echo "#  3. Copies changed files to a temporary directory           #"
    echo "#  4. Runs a JFrog SAST scan on those files                  #"
    echo "#  5. Generates a CSV report and displays results             #"
    echo "#  6. Keeps only the most recent reports, cleans up old/empty #"
    echo "#                                                             #"
    echo "# Usage: ./sast_scan.sh                                       #"
    echo "###############################################################"
    echo ""

    VCS=$(detect_vcs)

    if [ "$VCS" == "unknown" ]; then
        echo "Error: Not a Git or ClearCase repository. Exiting."
        exit 1
    fi

    echo "Detected version control system: $VCS"

    # Create a temporary directory to copy changed files
    TMP_DIR=$(mktemp -d)

    if [ "$VCS" == "git" ]; then
        CHANGED_FILES=$(get_git_changes)

        if [ -z "$CHANGED_FILES" ]; then
            echo "No changes detected. Exiting scan."
            rm -rf "$TMP_DIR"
            exit 0
        fi

        for file in $CHANGED_FILES; do
            rsync -Rr "$file" "$TMP_DIR"
        done

    elif [ "$VCS" == "clearcase" ]; then
        CHANGED_FILES=$(get_clearcase_changes)

        if [ -z "$CHANGED_FILES" ]; then
            echo "No changes detected. Exiting scan."
            rm -rf "$TMP_DIR"
            exit 0
        fi

        for file in $CHANGED_FILES; do
            rsync -Rr "$file" "$TMP_DIR"
        done
    fi

    echo -e "\n-----------------------------------------"
    echo "Copied changed files to temporary directory: $TMP_DIR"
    echo "-----------------------------------------"

    echo -e "\n========================================="
    echo "Running SAST scan and generating CSV and table output"
    echo "========================================="
    run_sast_scan "$TMP_DIR"

    # Clean up the temporary directory
    echo "Cleaning up temporary files..."
    #rm -rf "$TMP_DIR"
    echo "Scan complete."
}

# Run the main function
main
