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
export JFROG_CLI_HIDE_SURVEY=true

# --- Prerequisites Check ---

check_prerequisites() {
    local missing_prereqs=()
    local optional_missing=()

    echo "========================================="
    echo "Checking prerequisites..."
    echo "========================================="

    # Check JFrog CLI
    if ! command -v jf >/dev/null 2>&1; then
        missing_prereqs+=("JFrog CLI (jf)")
        echo "❌ JFrog CLI not found"
        echo "   Install from: https://jfrog.com/getcli/"
    else
        echo "✅ JFrog CLI found: $(jf --version 2>/dev/null | head -1 || echo 'version unknown')"

        # Check if JFrog CLI is configured
        if ! jf config show >/dev/null 2>&1; then
            echo "⚠️  JFrog CLI found but may not be configured"
            echo "   Run 'jf config add' to configure your JFrog instance"
        else
            echo "✅ JFrog CLI appears to be configured"
        fi
    fi

    # Check jq
    if ! command -v jq >/dev/null 2>&1; then
        missing_prereqs+=("jq")
        echo "❌ jq not found"
        echo "   On macOS: brew install jq"
        echo "   On Ubuntu/Debian: sudo apt-get install jq"
        echo "   On CentOS/RHEL: sudo yum install jq"
    else
        echo "✅ jq found: $(jq --version)"
    fi

    # Check rsync
    if ! command -v rsync >/dev/null 2>&1; then
        missing_prereqs+=("rsync")
        echo "❌ rsync not found"
        echo "   On macOS: should be pre-installed"
        echo "   On Ubuntu/Debian: sudo apt-get install rsync"
        echo "   On CentOS/RHEL: sudo yum install rsync"
    else
        echo "✅ rsync found: $(rsync --version | head -1)"
    fi

    # Check awk
    if ! command -v awk >/dev/null 2>&1; then
        missing_prereqs+=("awk")
        echo "❌ awk not found"
        echo "   Should be available on most Unix-like systems"
    else
        echo "✅ awk found: $(awk --version 2>/dev/null | head -1 || echo 'version unknown')"
    fi

    # Check column (optional)
    if ! command -v column >/dev/null 2>&1; then
        optional_missing+=("column")
        echo "⚠️  column utility not found (optional)"
        echo "   Table output will use raw CSV format instead"
        echo "   On macOS: should be pre-installed"
        echo "   On Ubuntu/Debian: sudo apt-get install bsdmainutils"
    else
        echo "✅ column found (optional utility for table formatting)"
    fi

    # Check git
    if ! command -v git >/dev/null 2>&1; then
        echo "⚠️  git not found"
        echo "   On macOS: brew install git or install Xcode Command Line Tools"
        echo "   On Ubuntu/Debian: sudo apt-get install git"
        echo "   On CentOS/RHEL: sudo yum install git"
    else
        echo "✅ git found: $(git --version)"
    fi

    # Check cleartool
    if ! command -v /usr/atria/bin/cleartool >/dev/null 2>&1; then
        echo "⚠️  cleartool not found"
        echo "   ClearCase tools not installed or not in expected location (/usr/atria/bin/)"
        echo "   Install IBM Rational ClearCase if you need ClearCase support"
    else
        echo "✅ cleartool found: $(/usr/atria/bin/cleartool -version 2>/dev/null | head -1 || echo 'version unknown')"
    fi

    # Check version control access
    local vcs_available=false
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "✅ Git repository detected"
        vcs_available=true
    elif /usr/atria/bin/cleartool ls &>/dev/null 2>&1; then
        echo "✅ ClearCase repository detected"
        vcs_available=true
    else
        echo "❌ No Git or ClearCase repository detected"
        echo "   Please run this script from within a Git or ClearCase repository"
        missing_prereqs+=("Git or ClearCase repository access")
    fi

    echo "========================================="

    # Report results
    if [ ${#missing_prereqs[@]} -gt 0 ]; then
        echo "❌ Missing required prerequisites:"
        for prereq in "${missing_prereqs[@]}"; do
            echo "   - $prereq"
        done
        echo ""
        echo "Please install the missing prerequisites and try again."
        return 1
    fi

    if [ ${#optional_missing[@]} -gt 0 ]; then
        echo "⚠️  Optional prerequisites missing (script will still work):"
        for prereq in "${optional_missing[@]}"; do
            echo "   - $prereq"
        done
        echo ""
    fi

    echo "✅ All required prerequisites are met!"
    echo "========================================="
    return 0
}

# --- Functions ---

# Function to detect the version control system
detect_vcs() {
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "git"
    elif /usr/atria/bin/cleartool ls &>/dev/null; then
        echo "clearcase"
    else
        echo "unknown"
    fi
}

# Function to get changed files from a Git repository
get_git_changes() {
    local files=($(git status --porcelain | awk '{print $2}'))

    # Print all files with serial numbers
    if [ ${#files[@]} -gt 0 ]; then
        echo "Git changed files:" >&2
        for i in "${!files[@]}"; do
            echo "$((i+1)). ${files[$i]}" >&2
        done
    fi

    # Return the files
    printf '%s\n' "${files[@]}"
}

############################################ Function to get changed files from a ClearCase repository
get_clearcase_changes() {
    # First, get the current branch name
    local branch=$(/usr/atria/bin/cleartool catcs | awk '/\.\.\.\/\/ {sub(/.*\.\.\.\/\//,""); sub(/\/LATEST.*/,""); print; exit}')

    # Check if we got a valid branch name (not "lost+found -none")
    if [ -z "$branch" ] || [[ "$branch" == *"lost+found"* ]]; then
        echo "Error: No proper ClearCase view is set or invalid branch detected: $branch" >&2
        return 1
    fi

    echo "Detected ClearCase branch: $branch" >&2

    # Find all modified files on the current branch (both checked out and checked in)
    local files=($(/usr/atria/bin/cleartool find -avobs -type f -ver "{brtype($branch)}" -nxn -print))

    # Print all files with serial numbers
    if [ ${#files[@]} -gt 0 ]; then
        echo "ClearCase changed files:" >&2
        for i in "${!files[@]}"; do
            echo "$((i+1)). ${files[$i]}" >&2
        done
    fi

    # Return the files
    printf '%s\n' "${files[@]}"
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

    # Check prerequisites first
    if ! check_prerequisites; then
        echo "Exiting due to missing prerequisites."
        exit 1
    fi

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
    rm -rf "$TMP_DIR"
    echo "Scan complete."
}

# Run the main function
main
