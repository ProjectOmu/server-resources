The files in the `systemd` directory are for the purposes of automating this script.

The script is intended to truncate admin logs after a set retention period, clearing them and vacuuming to preserve space.

The use-case for this script is for large tables that preserve logs on the server, specifically for SS14 servers with multiple servers pushing logs to the database.