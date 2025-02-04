#!/bin/bash
# setup_tap_runner.sh
# This script creates a systemd service that runs the command
# "./tap runner start" in /home/user/runner at boot with extra environment variables,
# then reloads systemd, enables, and starts the service.

set -e

# Ensure the script is run as root.
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root. Use sudo or log in as root."
  exit 1
fi

# Define variables.
SERVICE_FILE="/etc/systemd/system/tap-runner.service"
USERNAME="user"  # Change this if your username is different.
WORKING_DIR="/home/$USERNAME/runner"
EXECUTABLE="$WORKING_DIR/tap"
SERVICE_DESCRIPTION="Tap Runner Startup Service"
DOTNET_ROOT="/home/$USERNAME/.dotnet"

# Create the systemd service file with extra environment variables.
echo "Creating systemd service file at $SERVICE_FILE..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=$SERVICE_DESCRIPTION
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORKING_DIR
Environment="DOTNET_ROOT=$DOTNET_ROOT"
# Adjust the base PATH as needed for your system.
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$DOTNET_ROOT:$DOTNET_ROOT/tools"
ExecStart=$EXECUTABLE runner start
User=$USERNAME
Group=$USERNAME
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd to pick up the new service.
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Enable the service to start at boot.
echo "Enabling tap-runner.service to start at boot..."
systemctl enable tap-runner.service

# Start the service immediately.
echo "Starting tap-runner.service..."
systemctl start tap-runner.service

# Optionally display the service status.
echo "Service status:"
systemctl status tap-runner.service --no-pager
