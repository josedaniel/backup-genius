#!/bin/bash

# ======================================================
# 📦 Backup Genius - A powerful backup utility
# ======================================================

# 🔍 Script configuration
CONFIG_FILE="backup-config.json"
OPTIONS_FILE="options.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# 📚 Function to log messages
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message"
}

# ✅ Function to check if required commands are available
check_requirements() {
    log_message "INFO" "🔍 Checking required dependencies..."

    local missing_deps=0

    # Check for jq
    if ! command -v jq &> /dev/null; then
        log_message "ERROR" "❌ jq is required but not installed. Please install it."
        missing_deps=1
    fi

    # Check for zip
    if ! command -v zip &> /dev/null; then
        log_message "ERROR" "❌ zip is required but not installed. Please install it."
        missing_deps=1
    fi

    # Check for sqlite3 if enabled
    if [[ $(jq -r '.sqlite_enable' "$SCRIPT_DIR/$OPTIONS_FILE") == "true" ]]; then
        if ! command -v sqlite3 &> /dev/null; then
            log_message "ERROR" "❌ sqlite3 is required but not installed. Please install it."
            missing_deps=1
        fi
    fi

    # Check for mysql tools if needed
    local db_engines=$(jq -r '.[] | select(.databases != null and .databases | length > 0) | .db_engine' "$SCRIPT_DIR/$CONFIG_FILE" | sort | uniq)
    if [[ "$db_engines" == *"mysql"* ]]; then
        if ! command -v mysqldump &> /dev/null; then
            log_message "ERROR" "❌ mysqldump is required but not installed. Please install it."
            missing_deps=1
        fi
    fi

    # Check for sftp if enabled
    local sftp_enabled=$(jq -r '.[] | select(.sftp_enable == true) | .project' "$SCRIPT_DIR/$CONFIG_FILE")
    if [[ -n "$sftp_enabled" ]]; then
        if ! command -v sftp &> /dev/null; then
            log_message "ERROR" "❌ sftp is required but not installed. Please install it."
            missing_deps=1
        fi

        # Check for expect which is needed for automated SFTP uploads
        if ! command -v expect &> /dev/null; then
            log_message "ERROR" "❌ expect is required for SFTP automation but not installed. Please install it."
            missing_deps=1
        fi
    fi

    if [[ $missing_deps -eq 1 ]]; then
        log_message "ERROR" "❌ Missing dependencies. Please install them and try again."
        exit 1
    fi

    log_message "INFO" "✅ All dependencies are installed."
}

# 📊 Function to initialize SQLite database if enabled
initialize_sqlite() {
    local sqlite_enable=$(jq -r '.sqlite_enable' "$SCRIPT_DIR/$OPTIONS_FILE")

    if [[ "$sqlite_enable" == "true" ]]; then
        local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

        log_message "INFO" "🔄 Initializing SQLite database at $sqlite_file"

        # Create the database and table if they don't exist
        sqlite3 "$sqlite_file" <<EOF
CREATE TABLE IF NOT EXISTS backup_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    status TEXT NOT NULL,
    file_path TEXT NOT NULL,
    message TEXT,
    uploaded INTEGER DEFAULT 0,
    notified INTEGER DEFAULT 0
);
EOF

        if [[ $? -ne 0 ]]; then
            log_message "ERROR" "❌ Failed to initialize SQLite database."
            return 1
        fi

        log_message "INFO" "✅ SQLite database initialized successfully."
    fi

    return 0
}

# 💾 Function to log to SQLite
log_to_sqlite() {
    local project=$1
    local status=$2
    local file_path=$3
    local message=$4

    local sqlite_enable=$(jq -r '.sqlite_enable' "$SCRIPT_DIR/$OPTIONS_FILE")

    if [[ "$sqlite_enable" == "true" ]]; then
        local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

        log_message "INFO" "📝 Logging backup information to SQLite"

        sqlite3 "$sqlite_file" <<EOF
INSERT INTO backup_logs (project, timestamp, status, file_path, message)
VALUES ('$project', datetime('now'), '$status', '$file_path', '$message');
EOF

        if [[ $? -ne 0 ]]; then
            log_message "ERROR" "❌ Failed to log to SQLite database."
            return 1
        fi
    fi

    return 0
}

# 🔔 Function to send notifications
send_notification() {
    local project=$1
    local status=$2
    local message=$3

    log_message "INFO" "🔔 Sending notification for $project: $status"

    # Microsoft Teams notification
    local msteams_enable=$(jq -r '.msteams_enable' "$SCRIPT_DIR/$OPTIONS_FILE")
    if [[ "$msteams_enable" == "true" ]]; then
        local webhook_uri=$(jq -r '.msteams_webhook_uri' "$SCRIPT_DIR/$OPTIONS_FILE")

        # Create MS Teams message card
        local color="ff0000"
        if [[ "$status" == "SUCCESS" ]]; then
            color="00ff00"
        fi

        local payload="{
            \"@type\": \"MessageCard\",
            \"@context\": \"http://schema.org/extensions\",
            \"themeColor\": \"$color\",
            \"summary\": \"Backup $status for $project\",
            \"sections\": [{
                \"activityTitle\": \"Backup $status for $project\",
                \"facts\": [{
                    \"name\": \"Status\",
                    \"value\": \"$status\"
                }, {
                    \"name\": \"Time\",
                    \"value\": \"$(date)\"
                }, {
                    \"name\": \"Message\",
                    \"value\": \"$message\"
                }]
            }]
        }"

        curl -s -H "Content-Type: application/json" -d "$payload" "$webhook_uri"
        local curl_exit_code=$?

        if [[ $curl_exit_code -ne 0 ]]; then
            log_message "ERROR" "❌ Failed to send Microsoft Teams notification for $project. Exit code: $curl_exit_code"
        else
            log_message "INFO" "✅ Microsoft Teams notification sent successfully for $project"

            # Update SQLite record with notification status if enabled
            if [[ $(jq -r '.sqlite_enable' "$SCRIPT_DIR/$OPTIONS_FILE") == "true" ]]; then
                local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

                sqlite3 "$sqlite_file" <<EOF
UPDATE backup_logs
SET notified = 1
WHERE project = '$project' AND status = '$status'
ORDER BY id DESC LIMIT 1;
EOF
            fi
        fi
    fi

    # Slack notification
    local slack_enable=$(jq -r '.slack_enable' "$SCRIPT_DIR/$OPTIONS_FILE")
    if [[ "$slack_enable" == "true" ]]; then
        local webhook_uri=$(jq -r '.slack_webhook_uri' "$SCRIPT_DIR/$OPTIONS_FILE")

        # Create Slack message
        local color="danger"
        if [[ "$status" == "SUCCESS" ]]; then
            color="good"
        fi

        local payload="{
            \"attachments\": [{
                \"color\": \"$color\",
                \"pretext\": \"Backup $status for $project\",
                \"fields\": [{
                    \"title\": \"Status\",
                    \"value\": \"$status\",
                    \"short\": true
                }, {
                    \"title\": \"Time\",
                    \"value\": \"$(date)\",
                    \"short\": true
                }, {
                    \"title\": \"Message\",
                    \"value\": \"$message\",
                    \"short\": false
                }]
            }]
        }"

        curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$webhook_uri"
        local curl_exit_code=$?

        if [[ $curl_exit_code -ne 0 ]]; then
            log_message "ERROR" "❌ Failed to send Slack notification for $project. Exit code: $curl_exit_code"
        else
            log_message "INFO" "✅ Slack notification sent successfully for $project"

            # Update SQLite record with notification status if enabled
            if [[ $(jq -r '.sqlite_enable' "$SCRIPT_DIR/$OPTIONS_FILE") == "true" && $(jq -r '.msteams_enable' "$SCRIPT_DIR/$OPTIONS_FILE") == "false" ]]; then
                local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

                sqlite3 "$sqlite_file" <<EOF
UPDATE backup_logs
SET notified = 1
WHERE project = '$project' AND status = '$status'
ORDER BY id DESC LIMIT 1;
EOF
            fi
        fi
    fi

    # If neither Teams nor Slack is enabled but SQLite is, mark as notified
    if [[ "$msteams_enable" == "false" && "$slack_enable" == "false" && $(jq -r '.sqlite_enable' "$SCRIPT_DIR/$OPTIONS_FILE") == "true" ]]; then
        local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

        sqlite3 "$sqlite_file" <<EOF
UPDATE backup_logs
SET notified = 1
WHERE project = '$project' AND status = '$status'
ORDER BY id DESC LIMIT 1;
EOF

        log_message "INFO" "ℹ️ No notification services enabled, marked as notified in database for $project"
    fi

    return 0
}

# 📤 Function to upload backup via SFTP
upload_via_sftp() {
    local project=$1
    local backup_file=$2
    local sftp_host=$3
    local sftp_username=$4
    local sftp_password=$5
    local sftp_route=$6

    log_message "INFO" "📤 Uploading backup for $project via SFTP"

    # Create expect script for automated SFTP
    local expect_script=$(mktemp)

    # Double escape $ characters in username for expect script
    # $ must be escaped twice: once for bash and once for expect
    local escaped_username=$(echo "$sftp_username" | sed 's/\$/\\\$/g')

    cat > "$expect_script" <<EOF
#!/usr/bin/expect -f
# Escape $ for expect by using \\$
spawn sftp "$escaped_username@$sftp_host"
expect "password:"
send "$sftp_password\r"
expect "sftp>"
send "cd \"$sftp_route\"\r"
expect "sftp>"
send "put \"$backup_file\"\r"
expect "sftp>"
send "bye\r"
expect eof
EOF

    chmod +x "$expect_script"

    # Execute expect script
    "$expect_script"
    local exit_code=$?

    # Remove temporary expect script
    rm -f "$expect_script"

    if [[ $exit_code -ne 0 ]]; then
        log_message "ERROR" "❌ Failed to upload backup via SFTP"
        return 1
    fi

    log_message "INFO" "✅ Backup uploaded successfully via SFTP to remote path: $sftp_route"
    return 0
}

# 💾 Function to backup MySQL databases
backup_mysql_database() {
    local database=$1
    local host=$2
    local username=$3
    local password=$4
    local temp_dir=$5

    log_message "INFO" "💾 Backing up MySQL database: $database"

    local dump_file="$temp_dir/$database.sql"

    # Use MySQL credentials to dump database
    mysqldump --host="$host" --user="$username" --password="$password" "$database" > "$dump_file"

    if [[ $? -ne 0 ]]; then
        log_message "ERROR" "❌ Failed to backup MySQL database: $database"
        return 1
    fi

    log_message "INFO" "✅ Database backup completed: $database"
    return 0
}

# 📦 Function to perform backup for a project
perform_backup() {
    local project_json=$1

    # Extract project properties
    local project=$(echo "$project_json" | jq -r '.project')
    log_message "INFO" "🚀 Starting backup for project: $project"

    # Get backup location from options
    local backup_location=$(jq -r '.backup_location_folder' "$SCRIPT_DIR/$OPTIONS_FILE")
    if [[ ! -d "$backup_location" ]]; then
        mkdir -p "$backup_location"
    fi

    # Create timestamp-based backup filename
    local backup_filename="${project}_${CURRENT_TIMESTAMP}.zip"
    local backup_filepath="$backup_location/$backup_filename"

    # Create temporary directory
    local temp_dir=$(mktemp -d)
    log_message "INFO" "📁 Created temporary directory: $temp_dir"

    # Process files
    local files=$(echo "$project_json" | jq -r '.files[]?')
    if [[ -n "$files" ]]; then
        log_message "INFO" "📄 Copying files for backup"

        mkdir -p "$temp_dir/files"

        echo "$files" | while read -r file; do
            if [[ -f "$file" ]]; then
                cp "$file" "$temp_dir/files/"
                log_message "INFO" "📄 Copied file: $file"
            else
                log_message "WARNING" "⚠️ File not found: $file"
            fi
        done
    fi

    # Process folders
    local folders=$(echo "$project_json" | jq -r '.folders[]?')
    if [[ -n "$folders" ]]; then
        log_message "INFO" "📁 Copying folders for backup"

        mkdir -p "$temp_dir/folders"

        echo "$folders" | while read -r folder; do
            if [[ -d "$folder" ]]; then
                folder_name=$(basename "$folder")
                cp -r "$folder" "$temp_dir/folders/$folder_name"
                log_message "INFO" "📁 Copied folder: $folder"
            else
                log_message "WARNING" "⚠️ Folder not found: $folder"
            fi
        done
    fi

    # Process databases
    local databases=$(echo "$project_json" | jq -r '.databases[]?')
    if [[ -n "$databases" ]]; then
        local db_engine=$(echo "$project_json" | jq -r '.db_engine')

        if [[ "$db_engine" == "mysql" ]]; then
            log_message "INFO" "🗄️ Processing MySQL databases"

            mkdir -p "$temp_dir/databases"

            local db_host=$(echo "$project_json" | jq -r '.["database-credentials"].host')
            local db_username=$(echo "$project_json" | jq -r '.["database-credentials"].username')
            local db_password=$(echo "$project_json" | jq -r '.["database-credentials"].password')

            echo "$databases" | while read -r database; do
                backup_mysql_database "$database" "$db_host" "$db_username" "$db_password" "$temp_dir/databases"
            done
        else
            log_message "WARNING" "⚠️ Unsupported database engine: $db_engine"
        fi
    fi

    # Create zip archive
    log_message "INFO" "🗜️ Creating zip archive"
    (cd "$temp_dir" && zip -r "$backup_filepath" .)

    if [[ $? -ne 0 ]]; then
        log_message "ERROR" "❌ Failed to create backup archive"
        rm -rf "$temp_dir"
        log_to_sqlite "$project" "FAILED" "$backup_filepath" "Failed to create backup archive"
        send_notification "$project" "FAILED" "Failed to create backup archive"
        return 1
    fi

    log_message "INFO" "✅ Backup archive created: $backup_filepath"

    # Clean up temporary directory
    rm -rf "$temp_dir"

    # Upload via SFTP if enabled
    local sftp_enable=$(echo "$project_json" | jq -r '.sftp_enable')
    if [[ "$sftp_enable" == "true" ]]; then
        local sftp_host=$(echo "$project_json" | jq -r '.sftp_host')
        local sftp_username=$(echo "$project_json" | jq -r '.sftp_username')
        local sftp_password=$(echo "$project_json" | jq -r '.sftp_password')
        local sftp_route=$(echo "$project_json" | jq -r '.sftp_route')

        upload_via_sftp "$project" "$backup_filepath" "$sftp_host" "$sftp_username" "$sftp_password" "$sftp_route"
        local upload_status=$?

        # Update SQLite record with upload status
        if [[ $(jq -r '.sqlite_enable' "$SCRIPT_DIR/$OPTIONS_FILE") == "true" ]]; then
            local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

            sqlite3 "$sqlite_file" <<EOF
UPDATE backup_logs
SET uploaded = $([[ $upload_status -eq 0 ]] && echo 1 || echo 0)
WHERE project = '$project' AND file_path = '$backup_filepath';
EOF
        fi

        # Delete backup file after upload if configured
        if [[ $upload_status -eq 0 && $(jq -r '.delete_after_upload' "$SCRIPT_DIR/$OPTIONS_FILE") == "true" ]]; then
            log_message "INFO" "🗑️ Deleting local backup file after successful upload"
            rm -f "$backup_filepath"
        fi
    fi

    # Log success to SQLite
    log_to_sqlite "$project" "SUCCESS" "$backup_filepath" "Backup completed successfully"

    # Send notification
    send_notification "$project" "SUCCESS" "Backup completed successfully"

    log_message "INFO" "✅ Backup process completed for project: $project"
    return 0
}

# 🔄 Function to check if backup is needed based on frequency
is_backup_needed() {
    local project=$1
    local frequency=$2

    local sqlite_enable=$(jq -r '.sqlite_enable' "$SCRIPT_DIR/$OPTIONS_FILE")

    if [[ "$sqlite_enable" == "true" ]]; then
        local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

        # Check if we need to run the backup based on frequency (in minutes)
        local last_backup_time=$(sqlite3 "$sqlite_file" "SELECT datetime(timestamp) FROM backup_logs WHERE project = '$project' AND status = 'SUCCESS' ORDER BY timestamp DESC LIMIT 1;")

        if [[ -n "$last_backup_time" ]]; then
            # Calculate time difference in minutes
            local last_backup_epoch
            local current_epoch=$(date +%s)

            # Cross-platform date conversion (works on both Linux and macOS)
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS version
                last_backup_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_backup_time" +%s)
            else
                # Linux version
                last_backup_epoch=$(date -d "$last_backup_time" +%s)
            fi

            local diff_minutes=$(( (current_epoch - last_backup_epoch) / 60 ))

            if [[ $diff_minutes -lt $frequency ]]; then
                log_message "INFO" "⏱️ Skipping backup for $project. Last backup was $diff_minutes minutes ago (frequency: $frequency minutes)"
                return 1
            fi
        fi
    fi

    return 0
}

# 🔄 Main function
main() {
    log_message "INFO" "🚀 Starting Backup Genius"

    # Check if configuration files exist
    if [[ ! -f "$SCRIPT_DIR/$CONFIG_FILE" ]]; then
        log_message "ERROR" "❌ Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    if [[ ! -f "$SCRIPT_DIR/$OPTIONS_FILE" ]]; then
        log_message "ERROR" "❌ Options file not found: $OPTIONS_FILE"
        exit 1
    fi

    # Check requirements
    check_requirements

    # Initialize SQLite if enabled
    initialize_sqlite

    # Get all projects from configuration
    local projects=$(jq -c '.[]' "$SCRIPT_DIR/$CONFIG_FILE")

    # Process each project
    echo "$projects" | while read -r project_json; do
        local project=$(echo "$project_json" | jq -r '.project')
        local frequency=$(echo "$project_json" | jq -r '.frequency')

        # Check if backup is needed based on frequency
        if is_backup_needed "$project" "$frequency"; then
            perform_backup "$project_json"
        fi
    done

    log_message "INFO" "✅ Backup Genius completed"
}

# Run the main function
main "$@"