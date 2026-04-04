import std/unittest
import test_utils

suite "Database Smoke Test":
  test "Selects and connects to local MySQL or TiDB":
    let attempt = tryCreateTestDatabaseBackend()

    if attempt.backend == nil:
      echo "No local test database available: ", attempt.error
      skip()
    else:
      let engineName = if attempt.config.port == 3306: "MySQL" else: "TiDB"
      echo "Selected test database: ", engineName, " at ", attempt.config.host, ":", attempt.config.port, "/", attempt.config.database

      check attempt.config.host.len > 0
      check attempt.config.database.len > 0
      check attempt.config.port in [3306, 4000] or attempt.config.port > 0
