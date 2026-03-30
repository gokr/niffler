#!/bin/bash
# Setup MySQL for Niffler - Run as root or with sudo
# This script creates the niffler database and user

set -e

echo "Setting up MySQL for Niffler..."
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "This script needs to run with sudo or as root"
    echo "Please run: sudo $0"
    exit 1
fi

# Create database and user
cat << 'EOF' | mysql
-- Create database
CREATE DATABASE IF NOT EXISTS niffler CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Drop existing niffler users to ensure clean setup
DROP USER IF EXISTS 'niffler'@'localhost';
DROP USER IF EXISTS 'niffler'@'127.0.0.1';
DROP USER IF EXISTS 'niffler'@'%';

-- Create niffler user with password
CREATE USER 'niffler'@'localhost' IDENTIFIED BY 'niffler_password';
CREATE USER 'niffler'@'127.0.0.1' IDENTIFIED BY 'niffler_password';

-- Grant all privileges on niffler database
GRANT ALL PRIVILEGES ON niffler.* TO 'niffler'@'localhost';
GRANT ALL PRIVILEGES ON niffler.* TO 'niffler'@'127.0.0.1';

-- Also grant global CREATE privilege so niffler can create its own database if needed
GRANT CREATE ON *.* TO 'niffler'@'localhost';
GRANT CREATE ON *.* TO 'niffler'@'127.0.0.1';

FLUSH PRIVILEGES;
EOF

echo "✓ Database 'niffler' created (or already exists)"
echo "✓ User 'niffler' created/updated with password 'niffler_password'"
echo "✓ Permissions granted"
echo ""
echo "Update your ~/.niffler/config.yaml with:"
echo ""
cat << 'EOF'
database:
  enabled: true
  host: "127.0.0.1"
  port: 3306
  database: "niffler"
  username: "niffler"
  password: "niffler_password"
  pool_size: 10
EOF
