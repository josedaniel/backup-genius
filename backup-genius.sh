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

    # Skip DEBUG messages in console output
    if [[ "$level" != "DEBUG" ]]; then
        echo "[$timestamp] [$level] $message"
    fi
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

    # Check for sqlite3 - now always required
    if ! command -v sqlite3 &> /dev/null; then
        log_message "ERROR" "❌ sqlite3 is required but not installed. Please install it."
        missing_deps=1
    fi

    # Check for mysql tools if needed
    # Only check projects with non-empty databases array
    local db_engines=$(jq -r '.[] | select(.databases != null and (.databases | length > 0)) | .db_engine' "$SCRIPT_DIR/$CONFIG_FILE" 2>/dev/null | sort | uniq)
    if [[ "$db_engines" == *"mysql"* ]]; then
        if ! command -v mysqldump &> /dev/null; then
            log_message "ERROR" "❌ mysqldump is required but not installed. Please install it."
            missing_deps=1
        fi
    fi

    # Check for lftp if enabled
    # Only check projects with sftp_enable set to true (we'll keep the config name for simplicity)
    local lftp_enabled=$(jq -r '.[] | select(.sftp_enable == true) | .project' "$SCRIPT_DIR/$CONFIG_FILE" 2>/dev/null)
    if [[ -n "$lftp_enabled" ]]; then
        if ! command -v lftp &> /dev/null; then
            log_message "ERROR" "❌ lftp is required for SFTP uploads but not installed. Please install it."
            missing_deps=1
        fi
    fi

    if [[ $missing_deps -eq 1 ]]; then
        log_message "ERROR" "❌ Missing dependencies. Please install them and try again."
        exit 1
    fi

    log_message "INFO" "✅ All dependencies are installed."
}

# 📊 Function to initialize SQLite database
initialize_sqlite() {
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
        log_message "ERROR" "❌ Error initializing SQLite database."
        return 1
    fi

    log_message "INFO" "✅ SQLite database initialized successfully."

    return 0
}

# 💾 Function to log to SQLite
log_to_sqlite() {
    local project=$1
    local status=$2
    local file_path=$3
    local message=$4

    local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

    # Check if the SQLite file exists and is accessible
    if [[ ! -f "$sqlite_file" && ! -w "$(dirname "$sqlite_file")" ]]; then
        log_message "ERROR" "❌ SQLite database file does not exist and directory is not writable: $sqlite_file"
        return 1
    fi

    log_message "INFO" "📝 Logging backup information to SQLite"

    # Store timestamp explicitly in UTC format with explicit timezone
    # This ensures SQLite does not apply any timezone offsets
    local current_utc_timestamp=$(date -u "+%Y-%m-%d %H:%M:%S")

    # Debug log to confirm we're storing UTC time
    log_message "DEBUG" "🕒 Storing timestamp in SQLite (UTC): $current_utc_timestamp"

    # Add more debug information
    log_message "DEBUG" "📊 SQL Data: project='$project', status='$status', file_path='$file_path'"

    # Ensure file path string is properly escaped for SQLite
    local escaped_file_path=$(echo "$file_path" | sed "s/'/''/g")
    local escaped_message=$(echo "$message" | sed "s/'/''/g")

    # Insert record with explicit column names to avoid any issues
    sqlite3 "$sqlite_file" <<EOF
INSERT INTO backup_logs (project, timestamp, status, file_path, message, uploaded, notified)
VALUES ('$project', '$current_utc_timestamp', '$status', '$escaped_file_path', '$escaped_message', 0, 0);
EOF

    local insert_result=$?
    if [[ $insert_result -ne 0 ]]; then
        log_message "ERROR" "❌ Failed to log to SQLite database. Error code: $insert_result"
        return 1
    fi

    # Verify the record was inserted
    local record_count=$(sqlite3 "$sqlite_file" "SELECT COUNT(*) FROM backup_logs WHERE project = '$project' AND file_path = '$escaped_file_path';")
    log_message "INFO" "✅ SQLite record inserted successfully. Record count: $record_count"

    return 0
}

# 🔔 Function to send notifications
send_notification() {
    local project=$1
    local status=$2
    local message=$3
    local file_path=$4  # Adding file_path parameter to identify specific backup file

    log_message "INFO" "🔔 Sending notification for $project: $status"

    # Get SFTP/LFTP upload status from SQLite database
    local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")
    local upload_status="Not uploaded ❌"

    if [[ -n "$file_path" ]]; then
        # Escape file path for SQLite query
        local escaped_file_path_query=$(echo "$file_path" | sed "s/'/''/g")
        local uploaded=$(sqlite3 "$sqlite_file" "SELECT uploaded FROM backup_logs WHERE project = '$project' AND file_path = '$escaped_file_path_query' ORDER BY id DESC LIMIT 1;")
        if [[ "$uploaded" == "1" ]]; then
            upload_status="Uploaded ✅"
        fi
    fi

    log_message "INFO" "📊 Upload status for notification: $upload_status"

    # Microsoft Teams notification
    local msteams_enable=$(jq -r '.msteams_enable' "$SCRIPT_DIR/$OPTIONS_FILE")
    if [[ "$msteams_enable" == "true" ]]; then
        local webhook_uri=$(jq -r '.msteams_webhook_uri' "$SCRIPT_DIR/$OPTIONS_FILE")

        # Add status emoji
        local status_emoji="🔴"
        if [[ "$status" == "SUCCESS" ]]; then
            status_emoji="✅"
        fi

        # Prepare message text content with all relevant information
        local notification_text="## 🔄 Backup $status for $project\n\n"
        notification_text+="**Status:** $status_emoji $status\n"
        notification_text+="**⏰ Time:** $(date)\n"
        notification_text+="**📝 Message:** $message\n"
        notification_text+="**📤 Upload:** $upload_status\n" # Changed label slightly

        # Create Teams message in the required format
        local payload="{
            \"type\": \"message\",
            \"attachments\": [
                {
                    \"contentType\": \"application/vnd.microsoft.card.adaptive\",
                    \"contentUrl\": null,
                    \"content\": {
                        \"\$schema\": \"http://adaptivecards.io/schemas/adaptive-card.json\",
                        \"type\": \"AdaptiveCard\",
                        \"version\": \"1.2\",
                        \"body\": [
                            {
                                \"type\": \"TextBlock\",
                                \"text\": \"$notification_text\",
                                \"wrap\": true
                            }
                        ]
                    }
                }
            ]
        }"

        curl -s -H "Content-Type: application/json" -d "$payload" "$webhook_uri"
        local curl_exit_code=$?

        if [[ $curl_exit_code -ne 0 ]]; then
            log_message "ERROR" "❌ Error sending Microsoft Teams notification for $project. Exit code: $curl_exit_code"
        else
            log_message "INFO" "✅ Microsoft Teams notification sent successfully for $project"
        fi
    fi

    # Slack notification
    local slack_enable=$(jq -r '.slack_enable' "$SCRIPT_DIR/$OPTIONS_FILE")
    if [[ "$slack_enable" == "true" ]]; then
        local webhook_uri=$(jq -r '.slack_webhook_uri' "$SCRIPT_DIR/$OPTIONS_FILE")

        # Create Slack message
        local color="danger"
        local status_emoji="🔴"
        if [[ "$status" == "SUCCESS" ]]; then
            color="good"
            status_emoji="✅"
        fi

        local payload="{
            \"attachments\": [{
                \"color\": \"$color\",
                \"pretext\": \"🔄 Backup $status for $project\",
                \"fields\": [{
                    \"title\": \"Status\",
                    \"value\": \"$status_emoji $status\",
                    \"short\": true
                }, {
                    \"title\": \"⏰ Time\",
                    \"value\": \"$(date)\",
                    \"short\": true
                }, {
                    \"title\": \"📝 Message\",
                    \"value\": \"$message\",
                    \"short\": false
                }, {
                    \"title\": \"📤 Upload\",
                    \"value\": \"$upload_status\",
                    \"short\": true
                }]
            }]
        }"

        curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$webhook_uri"
        local curl_exit_code=$?

        if [[ $curl_exit_code -ne 0 ]]; then
            log_message "ERROR" "❌ Error sending Slack notification for $project. Exit code: $curl_exit_code"
        else
            log_message "INFO" "✅ Slack notification sent successfully for $project"
        fi
    fi

    return 0
}

# 📤 Function to upload backup via LFTP
upload_via_lftp() {
    local project=$1
    local backup_file=$2
    local sftp_host=$3
    local sftp_username=$4
    local sftp_password=$5
    local sftp_route=$6

    log_message "INFO" "📤 Uploading backup for $project via LFTP to $sftp_host"

    # Ensure the backup file exists
    if [[ ! -f "$backup_file" ]]; then
        log_message "ERROR" "❌ Backup file not found for upload: $backup_file"
        return 1
    fi

    # Use lftp to connect and upload
    # -e: execute commands
    # set sftp:auto-confirm yes: Avoids issues with host key checking if needed
    # open: connect using sftp protocol, providing user and password
    # cd: change to the remote directory
    # put: upload the local file
    # bye: disconnect
    lftp -e "set sftp:auto-confirm yes; set net:timeout 30; set net:max-retries 3; set net:reconnect-interval-base 5; open -u \"$sftp_username\",\"$sftp_password\" sftp://\"$sftp_host\"; cd \"$sftp_route\"; put \"$backup_file\"; bye"

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_message "ERROR" "❌ Failed to upload backup via LFTP. Exit code: $exit_code"
        return 1
    fi

    log_message "INFO" "✅ Backup uploaded successfully via LFTP to remote path: $sftp_route"
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
    # Added --single-transaction for InnoDB consistency, --quick to avoid buffering large tables
    mysqldump --host="$host" --user="$username" --password="$password" --single-transaction --quick "$database" > "$dump_file"

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
        if [[ $? -ne 0 ]]; then
            log_message "ERROR" "❌ Failed to create backup directory: $backup_location"
            # Log failure to SQLite even if backup didn't start properly
            log_to_sqlite "$project" "FAILED" "N/A" "Failed to create backup directory $backup_location"
            send_notification "$project" "FAILED" "Failed to create backup directory $backup_location" "N/A"
            return 1
        fi
    fi

    # Create timestamp-based backup filename
    local backup_filename="${project}_${CURRENT_TIMESTAMP}.zip"
    local backup_filepath="$backup_location/$backup_filename"

    # Create temporary directory
    local temp_dir=$(mktemp -d)
    if [[ -z "$temp_dir" || ! -d "$temp_dir" ]]; then
        log_message "ERROR" "❌ Failed to create temporary directory"
        log_to_sqlite "$project" "FAILED" "$backup_filepath" "Failed to create temporary directory"
        send_notification "$project" "FAILED" "Failed to create temporary directory" "$backup_filepath"
        return 1
    fi
    log_message "INFO" "📁 Created temporary directory: $temp_dir"

    # Trap to ensure temp dir cleanup on exit or error
    trap 'rm -rf "$temp_dir"' EXIT

    local backup_failed=0 # Flag to track if any part failed

    # Process files
    local files_json=$(echo "$project_json" | jq -c '.files') # Get as JSON array
    if [[ "$files_json" != "null" && "$files_json" != "[]" ]]; then
        log_message "INFO" "📄 Copying files for backup"
        mkdir -p "$temp_dir/files"
        echo "$project_json" | jq -r '.files[]?' | while IFS= read -r file; do
            if [[ -z "$file" ]]; then continue; fi # Skip empty lines
            if [[ -f "$file" ]]; then
                cp "$file" "$temp_dir/files/"
                log_message "INFO" "📄 Copied file: $file"
            elif [[ -d "$file" ]]; then # Handle if a directory is mistakenly listed in files
                 log_message "WARNING" "⚠️ Item listed in 'files' is a directory, skipping: $file. Use 'folders' instead."
            else
                log_message "WARNING" "⚠️ File not found or not a regular file: $file"
                # Optionally set backup_failed=1 here if missing files are critical
            fi
        done
    fi

    # Process folders
    local folders_json=$(echo "$project_json" | jq -c '.folders') # Get as JSON array
    if [[ "$folders_json" != "null" && "$folders_json" != "[]" ]]; then
        log_message "INFO" "📁 Copying folders for backup"
        mkdir -p "$temp_dir/folders"
        echo "$project_json" | jq -r '.folders[]?' | while IFS= read -r folder; do
             if [[ -z "$folder" ]]; then continue; fi # Skip empty lines
            if [[ -d "$folder" ]]; then
                folder_name=$(basename "$folder")
                # Use rsync for potentially better handling of links, permissions etc.
                rsync -a "$folder" "$temp_dir/folders/"
                # cp -r "$folder" "$temp_dir/folders/$folder_name" # Original cp method
                log_message "INFO" "📁 Copied folder: $folder"
            elif [[ -f "$folder" ]]; then # Handle if a file is mistakenly listed in folders
                 log_message "WARNING" "⚠️ Item listed in 'folders' is a file, skipping: $folder. Use 'files' instead."
            else
                log_message "WARNING" "⚠️ Folder not found or not a directory: $folder"
                 # Optionally set backup_failed=1 here if missing folders are critical
            fi
        done
    fi

    # Process databases
    local databases_json=$(echo "$project_json" | jq -c '.databases') # Get as JSON array
    if [[ "$databases_json" != "null" && "$databases_json" != "[]" ]]; then
        local db_engine=$(echo "$project_json" | jq -r '.db_engine')

        if [[ "$db_engine" == "mysql" ]]; then
            log_message "INFO" "🗄️ Processing MySQL databases"
            mkdir -p "$temp_dir/databases"

            local db_host=$(echo "$project_json" | jq -r '.["database-credentials"].host')
            local db_username=$(echo "$project_json" | jq -r '.["database-credentials"].username')
            local db_password=$(echo "$project_json" | jq -r '.["database-credentials"].password')

            echo "$project_json" | jq -r '.databases[]?' | while IFS= read -r database; do
                 if [[ -z "$database" ]]; then continue; fi # Skip empty lines
                backup_mysql_database "$database" "$db_host" "$db_username" "$db_password" "$temp_dir/databases"
                if [[ $? -ne 0 ]]; then
                    backup_failed=1 # Mark backup as failed if DB dump fails
                fi
            done
        else
            log_message "WARNING" "⚠️ Unsupported database engine: $db_engine"
        fi
    fi

    # Check if temp directory is empty (nothing was backed up)
    if [ -z "$(ls -A "$temp_dir")" ]; then
        log_message "WARNING" "⚠️ Temporary directory is empty. No files, folders, or database dumps were created for project $project. Skipping zip and upload."
        rm -rf "$temp_dir"
        trap - EXIT # Remove trap as temp dir is already gone
        # Log this specific situation
        log_to_sqlite "$project" "WARNING" "N/A" "No data found to backup (check paths and DB config)"
        send_notification "$project" "WARNING" "No data found to backup (check paths and DB config)" "N/A"
        return 0 # Return success as the script ran, but note the warning
    fi


    # 1. Create zip archive
    log_message "INFO" "🗜️ Creating zip archive: $backup_filepath"
    (cd "$temp_dir" && zip -r "$backup_filepath" .)

    if [[ $? -ne 0 ]]; then
        log_message "ERROR" "❌ Failed to create backup archive"
        rm -rf "$temp_dir"
        trap - EXIT # Remove trap
        log_to_sqlite "$project" "FAILED" "$backup_filepath" "Failed to create backup archive"
        send_notification "$project" "FAILED" "Failed to create backup archive" "$backup_filepath"
        return 1
    fi

    log_message "INFO" "✅ Backup archive created: $backup_filepath"

    # Clean up temporary directory now that zip is created
    rm -rf "$temp_dir"
    trap - EXIT # Remove trap as temp dir is gone

    # If any previous step failed (like DB backup), mark the overall status as FAILED
    if [[ $backup_failed -eq 1 ]]; then
         log_message "ERROR" "❌ Backup process completed with errors (e.g., database dump failed). Check logs."
         log_to_sqlite "$project" "FAILED" "$backup_filepath" "Backup archive created, but errors occurred during process (e.g., DB dump failed)"
         send_notification "$project" "FAILED" "Backup archive created, but errors occurred during process" "$backup_filepath"
         # Decide if you still want to upload a potentially incomplete backup
         # return 1 # Uncomment to prevent upload if errors occurred
    fi

    # 2. Log successful (or partially successful if backup_failed=1) backup creation to SQLite
    # We log SUCCESS here assuming the zip was created, even if parts failed. Notification will reflect errors if any.
    # If backup_failed=1, we logged FAILED above, so only log SUCCESS if backup_failed=0
    if [[ $backup_failed -eq 0 ]]; then
        log_to_sqlite "$project" "SUCCESS" "$backup_filepath" "Backup archive created successfully"
        log_message "INFO" "📝 Backup record saved to SQLite database"
    fi


    # 3. Upload via LFTP if enabled
    local sftp_enable=$(echo "$project_json" | jq -r '.sftp_enable')
    local upload_successful=0 # 0 = no, 1 = yes

    if [[ "$sftp_enable" == "true" ]]; then
        local sftp_host=$(echo "$project_json" | jq -r '.sftp_host')
        local sftp_username=$(echo "$project_json" | jq -r '.sftp_username')
        local sftp_password=$(echo "$project_json" | jq -r '.sftp_password')
        local sftp_route=$(echo "$project_json" | jq -r '.sftp_route')

        upload_via_lftp "$project" "$backup_filepath" "$sftp_host" "$sftp_username" "$sftp_password" "$sftp_route"
        local upload_status=$?

        # Update SQLite record with upload status
        local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")
        # Escape file path for SQLite query
        local escaped_file_path_query=$(echo "$backup_filepath" | sed "s/'/''/g")

        if [[ $upload_status -eq 0 ]]; then
            log_message "INFO" "✅ Updating SQLite record: upload successful for $backup_filepath"
            sqlite3 "$sqlite_file" "UPDATE backup_logs SET uploaded = 1 WHERE project = '$project' AND file_path = '$escaped_file_path_query';"
            upload_successful=1
        else
            log_message "ERROR" "❌ Updating SQLite record: upload failed for $backup_filepath"
            # Ensure uploaded is set to 0 even if the record was just inserted
            sqlite3 "$sqlite_file" "UPDATE backup_logs SET uploaded = 0 WHERE project = '$project' AND file_path = '$escaped_file_path_query';"
            # Mark overall backup as FAILED if upload fails
            backup_failed=1
        fi

        # Small delay might not be needed with lftp, but keep if issues arise
        # sleep 1

        # Verify the update was successful by reading back the value
        local verify_upload=$(sqlite3 "$sqlite_file" "SELECT uploaded FROM backup_logs WHERE project = '$project' AND file_path = '$escaped_file_path_query';")
        log_message "INFO" "🔍 Verified upload status in SQLite: $([ "$verify_upload" == "1" ] && echo "Uploaded ✅" || echo "Not uploaded ❌")"

        # Delete backup file after successful upload if configured
        if [[ $upload_successful -eq 1 && $(jq -r '.delete_after_upload' "$SCRIPT_DIR/$OPTIONS_FILE") == "true" ]]; then
            log_message "INFO" "🗑️ Deleting local backup file after successful upload: $backup_filepath"
            rm -f "$backup_filepath"
            if [[ $? -ne 0 ]]; then
                 log_message "WARNING" "⚠️ Failed to delete local backup file: $backup_filepath"
            fi
        fi
    fi

    # 4. Send final notification
    # Determine final status based on backup_failed flag
    local final_status="SUCCESS"
    local final_message="Backup completed successfully"
    if [[ $backup_failed -eq 1 ]]; then
        final_status="FAILED"
        final_message="Backup process finished with errors (check logs for details)"
        # Adjust message if only upload failed
        if [[ $sftp_enable == "true" && $upload_successful -eq 0 ]]; then
             final_message="Backup archive created, but upload failed"
        fi
    fi

    send_notification "$project" "$final_status" "$final_message" "$backup_filepath"
    log_message "INFO" "🔔 Final notification sent for backup status: $final_status"

    log_message "INFO" "✅ Backup process finished for project: $project with status: $final_status"
    [[ $backup_failed -eq 1 ]] && return 1 || return 0
}


# 🔄 Function to check if backup is needed based on frequency
is_backup_needed() {
    local project=$1
    local frequency=$2 # Frequency in minutes

    # Validate frequency input
     if ! [[ "$frequency" =~ ^-?[0-9]+$ ]]; then
        log_message "WARNING" "⚠️ Invalid frequency '$frequency' for project $project. Skipping frequency check, backup will run."
        return 0 # Treat invalid frequency as "run now"
    fi


    # If frequency is -1, always run the backup (special case for forced execution)
    if [[ $frequency -eq -1 ]]; then
        log_message "INFO" "🔄 Frequency set to -1, forcing backup for $project"
        return 0
    fi

     # If frequency is 0, run only once (check if any successful backup exists)
    if [[ $frequency -eq 0 ]]; then
        local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")
        local success_count=$(sqlite3 "$sqlite_file" "SELECT COUNT(*) FROM backup_logs WHERE project = '$project' AND status = 'SUCCESS';")
        if [[ $success_count -gt 0 ]]; then
             log_message "INFO" "⏰ Skipping backup for $project. Frequency is 0 and a successful backup already exists."
             return 1
        else
             log_message "INFO" "🔄 Backup needed for $project. Frequency is 0 and no prior successful backup found."
             return 0
        fi
    fi

    # Log current time with timezone info for better debugging
    local current_local_time=$(date "+%Y-%m-%d %H:%M:%S %Z")
    local current_utc_time=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
    log_message "INFO" "⏰ Current local time: $current_local_time"
    log_message "INFO" "⏰ Current UTC time: $current_utc_time"

    local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

    # Get the last successful backup time in UTC format
    # Use simple SELECT to get the raw timestamp
    local last_backup_time=$(sqlite3 "$sqlite_file" "SELECT timestamp FROM backup_logs WHERE project = '$project' AND status = 'SUCCESS' ORDER BY id DESC LIMIT 1;")

    if [[ -n "$last_backup_time" ]]; then
        log_message "INFO" "⏰ Last successful backup time from database (UTC): $last_backup_time"

        # Get current time in the same format as SQLite uses
        local current_time_utc=$(date -u "+%Y-%m-%d %H:%M:%S")

        # Calculate the elapsed time in minutes since the last backup
        # Ensure both times are treated as UTC by julianday()
        local elapsed_minutes=$(sqlite3 "$sqlite_file" "SELECT CAST((julianday('$current_time_utc', 'utc') - julianday('$last_backup_time', 'utc')) * 24 * 60 AS INTEGER);")

        # Handle potential errors from sqlite3 calculation
        if [[ -z "$elapsed_minutes" || ! "$elapsed_minutes" =~ ^[0-9]+$ ]]; then
             log_message "WARNING" "⚠️ Could not calculate elapsed time for $project. Running backup."
             return 0
        fi


        log_message "DEBUG" "⏰ Minutes elapsed since last backup: $elapsed_minutes (frequency: $frequency minutes)"

        if [[ $elapsed_minutes -lt $frequency ]]; then
            local minutes_remaining=$(( frequency - elapsed_minutes ))
            log_message "INFO" "⏰ Skipping backup for $project. Next backup in approx $minutes_remaining minutes (frequency: $frequency minutes)"
            return 1
        else
            log_message "INFO" "🔄 Backup needed for $project. $elapsed_minutes minutes elapsed since last backup (frequency: $frequency minutes)"
        fi
    else
        log_message "INFO" "🆕 No previous successful backups found for $project. Running first backup."
    fi

    return 0
}

# 🔄 Main function
main() {
    log_message "INFO" "🚀 Starting Backup Genius"

    # Check if configuration files exist
    if [[ ! -f "$SCRIPT_DIR/$CONFIG_FILE" ]]; then
        log_message "ERROR" "❌ Configuration file not found: $SCRIPT_DIR/$CONFIG_FILE"
        exit 1
    fi

    if [[ ! -f "$SCRIPT_DIR/$OPTIONS_FILE" ]]; then
        log_message "ERROR" "❌ Options file not found: $SCRIPT_DIR/$OPTIONS_FILE"
        exit 1
    fi

    # Check requirements
    check_requirements

    # Initialize SQLite if enabled
    initialize_sqlite

    # Get all projects from configuration
    # Use map to handle potential errors in JSON parsing gracefully
    local projects_array=$(jq -c '. // empty' "$SCRIPT_DIR/$CONFIG_FILE")

    if [[ -z "$projects_array" || "$projects_array" == "null" ]]; then
         log_message "ERROR" "❌ Configuration file $CONFIG_FILE is empty or not valid JSON."
         exit 1
    fi

     # Check if it's an array
    if ! jq -e 'type == "array"' <<< "$projects_array" > /dev/null; then
        log_message "ERROR" "❌ Configuration file $CONFIG_FILE must contain a JSON array of projects."
        exit 1
    fi


    # Process each project using jq to iterate safely
    jq -c '.[]' "$SCRIPT_DIR/$CONFIG_FILE" | while IFS= read -r project_json; do
        local project=$(echo "$project_json" | jq -r '.project // "unknown_project"') # Provide default if name missing
        local frequency=$(echo "$project_json" | jq -r '.frequency // "-1"') # Default to -1 (run always) if missing

         log_message "INFO" "-------------------- Processing Project: $project --------------------"

        # Check if backup is needed based on frequency
        if is_backup_needed "$project" "$frequency"; then
            perform_backup "$project_json"
        fi
         log_message "INFO" "-------------------- Finished Project: $project --------------------"
         echo # Add a blank line for better log readability between projects
    done

    log_message "INFO" "✅ Backup Genius completed"
}

# Run the main function
main "$@"
