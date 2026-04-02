#!/bin/bash
# Setup MySQL for Niffler
# Run with: sudo ./setup_mysql.sh

set -e

echo "Setting up MySQL for Niffler..."

# Create database and user
mysql -e "
CREATE DATABASE IF NOT EXISTS niffler;

-- Create niffler user if it doesn't exist
CREATE USER IF NOT EXISTS 'niffler'@'localhost' IDENTIFIED BY 'niffler_password';
CREATE USER IF NOT EXISTS 'niffler'@'127.0.0.1' IDENTIFIED BY 'niffler_password';

-- Grant all privileges
GRANT ALL PRIVILEGES ON niffler.* TO 'niffler'@'localhost';
GRANT ALL PRIVILEGES ON niffler.* TO 'niffler'@'127.0.0.1';

FLUSH PRIVILEGES;
"

echo "✓ Database 'niffler' created"
echo "✓ User 'niffler' created with password 'niffler_password'"
echo ""
echo "Now update your ~/.niffler/config.yaml with:"
echo ""
echo "database:"
echo "  enabled: true"
echo "  host: \"127.0.0.1\""
echo "  port: 3306"
echo "  database: \"niffler\""
echo "  username: \"niffler\""
echo "  password: \"niffler_password\""
echo "  pool_size: 10"
