# Custom instructions for Copilot

- All comments, output messages and readme files should be in english.
- Use emoji to make the comments colorfull, without being overhelming.

## Project description

This project is a shell script that can backup files, folders and databases.

## Script configuration files:

- backup-config.json: it is json file with information about all the backup projects. Every project has the following information:
    - project: string. The name of this backup project. No spaces or special chars.
    - files: an array of independent files to backup.
    - folders: an array of full folders to backup.
    - databases: an array of databases to backup.
    - db_engine: string. If no databases, this should be empty. For now, only mysql is supported.
    - database-credentials:
        - host
        - username
        - password
    - sftp_enable: boolean.
    - sftp_host
    - sftp_username
    - sftp_password
    - frecuency: number. The amount of minutes between backups.

- options.json: it is json file with general options about the backup process. It allows the following keys:
    - sqlite_enable: boolean. Defines if it should store a record of the backup process on a local sqlite database.
    - sqlite_file: string. The route to store the database file.
    - msteams_enable: boolean. Defines if it should notify via Microsoft Teams when a backup failed or completed successfully.
    - msteams_webhook_uri: string.
    - slack_enable: boolean. Defines if it should notify via Slack when a backup failed or completed successfully.
    - slack_webhook_uri: string.
    - backup_location_folder: string. The absolute path the backups are going to be stored.
    - delete_after_upload: boolean

## Backup logic

- For every entry in the backup-config.json file, the script should create a single zip file containing the files, folders and databases defined in the setup.
- These zipfiles should be named after the name of the project plus a date and time string that helps to understand when it was generated.
- The backup zip files should be stored in the configured location.
- A backup file should be deleted only after it was uploaded, notifed, and stored in the sqlite database depending on the configuration.
