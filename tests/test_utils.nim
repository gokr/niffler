## Test utilities for niffler tests
## Provides centralized test configuration for local MySQL/TiDB setup

import std/[os, strutils, strformat]
import ../src/core/database
import ../src/types/config
import debby/pools
import debby/mysql

let testHost = getEnv("NIFFLER_TEST_DB_HOST", "127.0.0.1")
let testUser = getEnv("NIFFLER_TEST_DB_USER", "root")
let testDatabaseName = getEnv("NIFFLER_TEST_DB_NAME", "niffler_test")
let testPassword = getEnv("NIFFLER_TEST_DB_PASSWORD", "")
let testPoolSize = 1

proc getTestDatabasePorts*(): seq[int] =
  let explicitPort = getEnv("NIFFLER_TEST_DB_PORT", "")
  if explicitPort.len > 0:
    try:
      return @[parseInt(explicitPort)]
    except ValueError:
      discard
  return @[3306, 4000]

proc getTestDatabaseConfigs*(): seq[DatabaseConfig] =
  for port in getTestDatabasePorts():
    result.add(DatabaseConfig(
      enabled: true,
      host: testHost,
      port: port,
      database: testDatabaseName,
      username: testUser,
      password: testPassword,
      poolSize: testPoolSize
    ))

proc getPreferredTestDatabaseConfig*(): DatabaseConfig =
  ## Return the first configured test DB target (MySQL first, then TiDB fallback)
  return getTestDatabaseConfigs()[0]

proc tryCreateTestDatabaseBackend*(): tuple[backend: DatabaseBackend, config: DatabaseConfig, error: string] =
  ## Try configured test DB targets without exiting on failure
  var errors: seq[string] = @[]

  for dbConfig in getTestDatabaseConfigs():
    try:
      let backend = createDatabaseBackend(dbConfig)
      return (backend, dbConfig, "")
    except CatchableError as e:
      errors.add(fmt("{dbConfig.host}:{dbConfig.port} -> {e.msg}"))

  let preferred = getPreferredTestDatabaseConfig()
  return (nil, preferred, errors.join("; "))

proc createTestDatabaseBackend*(): DatabaseBackend =
  ## Create a test database backend connected to local MySQL first, TiDB second
  let attempt = tryCreateTestDatabaseBackend()
  if attempt.backend != nil:
    let engineName = if attempt.config.port == 3306: "MySQL" else: "TiDB"
    echo "\e[32m✓ ", engineName, " connected at ", attempt.config.host, ":", attempt.config.port, "/", attempt.config.database, "\e[0m"
    return attempt.backend

  echo "\e[31m✗ Failed to connect to local test database\e[0m"
  echo "Tried these targets:"
  for err in attempt.error.split("; "):
    echo err
  echo ""
  echo "To run tests, you can use either local MySQL or TiDB:"
  echo ""
  echo "MySQL example:"
  echo "  mysql -h 127.0.0.1 -P 3306 -u root -e 'CREATE DATABASE IF NOT EXISTS niffler_test'"
  echo ""
  echo "TiDB example:"
  echo "  docker run -d --name tidb -p 4000:4000 pingcap/tidb:latest"
  echo "  mysql -h 127.0.0.1 -P 4000 -u root -e 'CREATE DATABASE IF NOT EXISTS niffler_test'"
  echo ""
  echo "Environment overrides:"
  echo "  NIFFLER_TEST_DB_HOST, NIFFLER_TEST_DB_PORT, NIFFLER_TEST_DB_USER, NIFFLER_TEST_DB_PASSWORD, NIFFLER_TEST_DB_NAME"
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
      discard db.query("DELETE FROM message_thinking_blocks")  # Must be before conversation_message (FK)
      discard db.query("DELETE FROM conversation_message")
      discard db.query("DELETE FROM system_prompt_token_usage")
      discard db.query("DELETE FROM model_token_usage")
      discard db.query("DELETE FROM conversation")
      discard db.query("DELETE FROM token_log_entry")
      discard db.query("DELETE FROM prompt_history_entry")
    except CatchableError:
      # Ignore errors if tables don't exist or if foreign key constraints cause issues
      discard

  # Re-initialize schema if needed (create any missing tables)
  backend.initializeDatabase()
