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
    local db_engines=$(jq -r '.[] | select(.databases != null and (.databases | length > 0)) | .db_engine' "$SCRIPT_DIR/$CONFIG_FILE" | sort | uniq)
    if [[ "$db_engines" == *"mysql"* ]]; then
        if ! command -v mysqldump &> /dev/null; then
            log_message "ERROR" "❌ mysqldump is required but not installed. Please install it."
            missing_deps=1
        fi
    fi

    # Check for sftp if enabled
    # Only check projects with sftp_enable set to true
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

# 📊 Function to initialize SQLite database
initialize_sqlite() {
    local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

    log_message "INFO" "🔄 Inicializando base de datos SQLite en $sqlite_file"

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
        log_message "ERROR" "❌ Error al inicializar la base de datos SQLite."
        return 1
    fi

    log_message "INFO" "✅ Base de datos SQLite inicializada correctamente."

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

    log_message "INFO" "🔔 Enviando notificación para $project: $status"

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
            log_message "ERROR" "❌ Error al enviar notificación de Microsoft Teams para $project. Exit code: $curl_exit_code"
        else
            log_message "INFO" "✅ Notificación de Microsoft Teams enviada correctamente para $project"

            # Update SQLite record with notification status
            if [[ -n "$file_path" ]]; then
                sqlite3 "$sqlite_file" <<EOF
UPDATE backup_logs
SET notified = 1
WHERE project = '$project' AND file_path = '$file_path';
EOF
            else
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
                }]
            }]
        }"

        curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$webhook_uri"
        local curl_exit_code=$?

        if [[ $curl_exit_code -ne 0 ]]; then
            log_message "ERROR" "❌ Error al enviar notificación de Slack para $project. Exit code: $curl_exit_code"
        else
            log_message "INFO" "✅ Notificación de Slack enviada correctamente para $project"

            # Update SQLite record with notification status if MS Teams is not enabled
            if [[ "$msteams_enable" == "false" ]]; then
                if [[ -n "$file_path" ]]; then
                    sqlite3 "$sqlite_file" <<EOF
UPDATE backup_logs
SET notified = 1
WHERE project = '$project' AND file_path = '$file_path';
EOF
                else
                    sqlite3 "$sqlite_file" <<EOF
UPDATE backup_logs
SET notified = 1
WHERE project = '$project' AND status = '$status'
ORDER BY id DESC LIMIT 1;
EOF
                fi
            fi
        fi
    fi

    # If neither Teams nor Slack is enabled, mark as notified in database
    if [[ "$msteams_enable" == "false" && "$slack_enable" == "false" ]]; then
        sqlite3 "$sqlite_file" <<EOF
UPDATE backup_logs
SET notified = 1
WHERE project = '$project' AND status = '$status'
ORDER BY id DESC LIMIT 1;
EOF

        log_message "INFO" "ℹ️ No hay servicios de notificación habilitados, marcado como notificado en la base de datos para $project"
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
        send_notification "$project" "FAILED" "Failed to create backup archive" "$backup_filepath"
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
        local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

        # Set the uploaded flag correctly in database
        if [[ $upload_status -eq 0 ]]; then
            log_message "INFO" "✅ Updating SQLite record: upload successful for $backup_filepath"
            sqlite3 "$sqlite_file" "UPDATE backup_logs SET uploaded = 1 WHERE project = '$project' AND file_path = '$backup_filepath';"
        else
            log_message "INFO" "⚠️ Updating SQLite record: upload failed for $backup_filepath"
            sqlite3 "$sqlite_file" "UPDATE backup_logs SET uploaded = 0 WHERE project = '$project' AND file_path = '$backup_filepath';"
        fi

        # Small delay to ensure SQLite update completes
        sleep 1

        # Verify the update was successful by reading back the value
        local verify_upload=$(sqlite3 "$sqlite_file" "SELECT uploaded FROM backup_logs WHERE project = '$project' AND file_path = '$backup_filepath';")
        log_message "INFO" "🔍 Verified upload status in SQLite: $([ "$verify_upload" == "1" ] && echo "Uploaded ✅" || echo "Not uploaded ❌")"

        # Delete backup file after upload if configured
        if [[ $upload_status -eq 0 && $(jq -r '.delete_after_upload' "$SCRIPT_DIR/$OPTIONS_FILE") == "true" ]]; then
            log_message "INFO" "🗑️ Deleting local backup file after successful upload"
            rm -f "$backup_filepath"
        fi
    fi

    # Log success to SQLite
    log_to_sqlite "$project" "SUCCESS" "$backup_filepath" "Backup completed successfully"

    # Send notification
    send_notification "$project" "SUCCESS" "Backup completed successfully" "$backup_filepath"

    log_message "INFO" "✅ Backup process completed for project: $project"
    return 0
}

# 🔄 Function to check if backup is needed based on frequency
is_backup_needed() {
    local project=$1
    local frequency=$2

    # If frequency is -1, always run the backup (special case for forced execution)
    if [[ $frequency -eq -1 ]]; then
        log_message "INFO" "🔄 Frecuencia establecida en -1, forzando respaldo para $project"
        return 0
    fi

    # Log current time with timezone info for better debugging
    local current_local_time=$(date "+%Y-%m-%d %H:%M:%S %Z")
    local current_utc_time=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
    log_message "INFO" "🕒 Hora local actual: $current_local_time"
    log_message "INFO" "🕒 Hora UTC actual: $current_utc_time"

    local sqlite_file=$(jq -r '.sqlite_file' "$SCRIPT_DIR/$OPTIONS_FILE")

    # Get the last successful backup time in UTC format
    # Use simple SELECT to get the raw timestamp
    local last_backup_time=$(sqlite3 "$sqlite_file" "SELECT timestamp FROM backup_logs WHERE project = '$project' AND status = 'SUCCESS' ORDER BY id DESC LIMIT 1;")

    if [[ -n "$last_backup_time" ]]; then
        log_message "INFO" "🕒 Última hora de respaldo desde la base de datos: $last_backup_time"

        # Get current time in the same format as SQLite uses
        local current_time_utc=$(date -u "+%Y-%m-%d %H:%M:%S")

        # Get a more comparable version for debug
        local last_backup_formatted=$last_backup_time
        # Handle possible milliseconds in SQLite timestamps
        if [[ "$last_backup_time" == *"."* ]]; then
            last_backup_formatted=$(echo "$last_backup_time" | sed -E 's/\.[0-9]+//')
        fi

        log_message "DEBUG" "🔍 Comparando tiempos - Último respaldo: $last_backup_formatted | Actual: $current_time_utc"

        # Calculate the elapsed time in minutes since the last backup
        local elapsed_minutes=$(sqlite3 "$sqlite_file" "SELECT CAST((julianday('$current_time_utc') - julianday('$last_backup_time')) * 24 * 60 AS INTEGER);")

        log_message "DEBUG" "⏱️ Minutos transcurridos desde el último respaldo: $elapsed_minutes (frecuencia: $frequency minutos)"

        # For frequency 0, only run if some time has passed (at least 1 minute)
        if [[ $frequency -eq 0 && $elapsed_minutes -eq 0 ]]; then
            log_message "INFO" "⏱️ Omitiendo respaldo para $project. La frecuencia es 0 y no ha transcurrido tiempo desde el último respaldo."
            return 1
        # For any other frequency, run if the elapsed time is >= frequency
        elif [[ $elapsed_minutes -lt $frequency ]]; then
            local minutes_remaining=$(( frequency - elapsed_minutes ))
            log_message "INFO" "⏱️ Omitiendo respaldo para $project. Próximo respaldo en $minutes_remaining minutos (frecuencia: $frequency minutos)"
            return 1
        else
            log_message "INFO" "🔄 Respaldo necesario para $project. $elapsed_minutes minutos transcurridos desde el último respaldo (frecuencia: $frequency minutos)"
        fi
    else
        log_message "INFO" "🆕 No se encontraron respaldos exitosos previos para $project. Ejecutando el primer respaldo."
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