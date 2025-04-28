# 📦 backup-genius

## 📝 Description
`backup-genius` is a command-line tool designed to back up files, folders, and databases. It provides flexible configuration options and supports notifications and remote storage.

## ⚙️ Configuration

### Configuration Files

#### `backup-config.json`
This file defines the backup projects. Each project includes:
- **project**: Name of the project (no spaces or special characters).
- **files**: List of individual files to back up.
- **folders**: List of full folders to back up.
- **databases**: List of databases to back up.
- **db_engine**: Database engine (currently only `mysql` is supported).
- **database-credentials**:
  - **host**: Database host.
  - **username**: Database username.
  - **password**: Database password.
- **sftp_enable**: Enable or disable SFTP upload.
- **sftp_host**: SFTP server host.
- **sftp_username**: SFTP server username.
- **sftp_password**: SFTP server password.
- **frecuency**: Frequency in minutes between backups.

#### `options.json`
This file defines general options for the backup process:
- **sqlite_enable**: Enable or disable logging in a local SQLite database.
- **sqlite_file**: Path to store the SQLite file.
- **msteams_enable**: Enable or disable notifications in Microsoft Teams.
- **msteams_webhook_uri**: Microsoft Teams webhook URI.
- **slack_enable**: Enable or disable notifications in Slack.
- **slack_webhook_uri**: Slack webhook URI.
- **backup_location_folder**: Absolute path where backups will be stored.
- **delete_after_upload**: Delete the backup file after it is uploaded and logged.

## 🔄 Backup Logic
1. For each entry in `backup-config.json`, a ZIP file is created containing the configured files, folders, and databases.
2. The ZIP files are named using the project name and a timestamp.
3. The ZIP files are stored in the configured location.
4. Backup files are deleted only after:
   - Being successfully uploaded.
   - Notifications are sent (if enabled).
   - Logged in the SQLite database (if enabled).

## 🚀 Installation

### Setting Up Cron
To ensure the script runs automatically, you need to add an entry to your `cron` jobs. This will execute the script every minute.

1. Open the crontab editor:
   ```bash
   crontab -e
   ```

2. Add the following line to schedule the script:
   ```bash
   * * * * * /path/to/backup-genius.sh
   ```

   Replace `/path/to/backup-genius.sh` with the full path to the script.

3. Save and exit the editor.

The script will now run every minute, checking the configuration and performing backups as needed.

## 🔧 Requirements
The following dependencies are required to run backup-genius:

- **Bash-compatible shell** - To execute the script
- **jq** - Required for processing JSON configuration files
- **zip** - Required for creating backup archives
- **curl** - Used for sending notifications to MS Teams and Slack

Depending on your configuration, you may also need:

- **sqlite3** - Required if `sqlite_enable` is set to `true` in `options.json`
- **mysqldump** - Required if you're backing up MySQL databases
- **sftp** - Required if you're using SFTP to upload backup files
- **expect** - Required for automated SFTP uploads using passwords

### Installing dependencies

#### On Debian/Ubuntu
```bash
sudo apt-get update
sudo apt-get install jq zip curl sqlite3 mysql-client expect
```

#### On macOS (using Homebrew)
```bash
brew install jq zip curl sqlite mysql expect
```

#### On CentOS/RHEL
```bash
sudo yum install jq zip curl sqlite mysql-client expect
```

## 📋 Usage
1. Configure the `backup-config.json` and `options.json` files according to your needs.
2. Ensure the cron job is set up to run the script automatically.

## 👥 Contributing
Contributions are welcome. Please open an issue or pull request in this repository.

## 📄 License
This project is licensed under the MIT License.
