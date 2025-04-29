# 📦 backup-genius

## 📝 Description
`backup-genius` is a command-line tool designed to back up files, folders, and databases. It provides flexible configuration options and supports notifications and remote storage.

## 👤 Author
- **José Daniel Paternina** - [@josedaniel](https://x.com/josedaniel)

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

##### Example Configuration:
```json
[
  {
    "project": "my_website",
    "files": [
      "/var/www/html/wp-config.php",
      "/etc/nginx/sites-available/my-site.conf"
    ],
    "folders": [
      "/var/www/html/wp-content/uploads"
    ],
    "databases": [
      "wordpress_db"
    ],
    "db_engine": "mysql",
    "database-credentials": {
      "host": "localhost",
      "username": "db_user",
      "password": "secure_password"
    },
    "sftp_enable": true,
    "sftp_host": "backup.example.com",
    "sftp_username": "backup_user",
    "sftp_password": "sftp_password",
    "frecuency": 1440
  }
]
```

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

##### Example Configuration:
```json
{
  "sqlite_enable": true,
  "sqlite_file": "/var/log/backup-genius/backups.db",
  "msteams_enable": true,
  "msteams_webhook_uri": "https://outlook.office.com/webhook/...",
  "slack_enable": false,
  "slack_webhook_uri": "",
  "backup_location_folder": "/var/backups/backup-genius",
  "delete_after_upload": true
}
```

## 🔄 Backup Logic
1. For each entry in `backup-config.json`, a ZIP file is created containing the configured files, folders, and databases.
2. The ZIP files are named using the project name and a timestamp (e.g., `my_website_2025-04-28_132045.zip`).
3. The ZIP files are stored in the configured location.
4. Backup files are deleted only after:
   - Being successfully uploaded.
   - Notifications are sent (if enabled).
   - Logged in the SQLite database (if enabled).

## 🚀 Installation

### Quick Start Guide

1. Clone or download this repository to your server
2. Make the script executable:
   ```bash
   chmod +x backup-genius.sh
   ```
3. Install required dependencies (see Requirements section)
4. Configure your backup projects in `backup-config.json`
5. Configure general options in `options.json`
6. Set up a cron job to run the script regularly

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
3. To run the script manually for testing:
   ```bash
   ./backup-genius.sh
   ```

## 💡 Tips and Troubleshooting

### Log Files
The script creates log files in the backup location folder. Check these logs if you encounter any issues.

### Common Issues
- **Permission errors**: Ensure the script has necessary permissions to access all files and folders.
- **MySQL connection issues**: Verify database credentials and that the mysql-client can connect using those credentials.
- **SFTP failures**: Test SFTP connection manually to verify credentials and connectivity.

### Secure Storage of Passwords
For production use, consider more secure ways to store credentials:
- Use environment variables
- Implement a secure password vault
- Set appropriate file permissions (chmod 600) for configuration files

## 👥 Contributing
Contributions are welcome. Please open an issue or pull request in this repository.

## 📄 License
This project is licensed under the MIT License.

## 🔄 Version History
- **v1.0.0** - Initial release
