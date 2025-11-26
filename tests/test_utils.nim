## Test utilities for niffler tests
## Provides centralized test configuration and TiDB connection setup

import ../src/core/database
import ../src/types/config
import debby/pools
import debby/mysql

let testHost = "127.0.0.1"
let testPort = 4000
let testUser = "root"
let testDatabaseName = "niffler_test"
let testPassword = ""
let testPoolSize = 1

proc createTestDatabaseBackend*(): DatabaseBackend =
  ## Create a test database backend connected to local TiDB
  let dbConfig = DatabaseConfig(
    enabled: true,
    host: testHost,
    port: testPort,
    database: testDatabaseName,
    username: testUser,
    password: testPassword,
    poolSize: testPoolSize
  )

  try:
    result = createDatabaseBackend(dbConfig)
    echo "\e[32m✓ TiDB connected at ", testHost, ":", testPort, "/", testDatabaseName, "\e[0m"
  except CatchableError as e:
    echo "\e[31m✗ Failed to connect to TiDB at ", testHost, ":", testPort, "\e[0m"
    echo "Error: ", e.msg
    echo ""
    echo "To run tests, you need TiDB running locally:"
    echo ""
    echo "1. Install TiUP (easiest method):"
    echo "   curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh"
    echo ""
    echo "2. Start TiDB playground:"
    echo "   tiup playground"
    echo ""
    echo "3. Alternative: Use Docker:"
    echo "   docker run -d --name tidb -p 4000:4000 pingcap/tidb:latest"
    echo ""
    echo "4. Create test database:"
    echo "   mysql -h 127.0.0.1 -P 4000 -u root -e 'CREATE DATABASE IF NOT EXISTS niffler_test'"
    echo ""
    quit(1)

proc clearTestDatabase*(backend: DatabaseBackend) =
  ## Clear all data from test database tables (delete data, keep schema)
  backend.pool.withDb:
    # Delete all data from tables (keep schema for consistency between tests)
    try:
      # Clear data in order to respect foreign key constraints
      discard db.query("DELETE FROM token_correction_factor")
      discard db.query("DELETE FROM todo_item")
      discard db.query("DELETE FROM todo_list")
      discard db.query("DELETE FROM conversation_message")
      discard db.query("DELETE FROM conversation_thinking_token")
      discard db.query("DELETE FROM system_prompt_token_usage")
      discard db.query("DELETE FROM model_token_usage")
      discard db.query("DELETE FROM conversation")
      discard db.query("DELETE FROM token_log_entry")
      discard db.query("DELETE FROM prompt_history_entry")
      discard db.query("DELETE FROM token_correction_factor")
    except CatchableError:
      # Ignore errors if tables don't exist or if foreign key constraints cause issues
      discard

  # Re-initialize schema if needed (create any missing tables)
  backend.initializeDatabase()
