# SQL Unit Testing Framework – Java

A **JUnit 5 / Maven** test framework for validating the SQL Server stored procedures
`USP_DELTA_FOLDERS` and `USP_DELTA_MASTER`.  
This is the Java equivalent of the original Python/pytest framework located in
`unitesting-framework-main/`.

---

## Project Layout

```
unitesting-framework-java/
├── pom.xml                                         # Maven build descriptor
├── .gitlab-ci.yml                                  # CI pipeline (GitLab)
└── src/
    └── test/
        ├── java/com/delta/
        │   ├── DatabaseSetup.java                  # DB bootstrap utility
        │   ├── DbUtils.java                        # Shared JDBC helper methods
        │   ├── BaseTest.java                       # Base class for all tests
        │   ├── TestUspDeltaFolders.java            # Tests for USP_DELTA_FOLDERS (TC01–TC10)
        │   └── TestUspDeltaMaster.java             # Tests for USP_DELTA_MASTER  (TC01–TC03)
        └── resources/
            └── sql/
                ├── 01_create_tables.sql            # DDL: create all test tables
                └── 02_create_procedures.sql        # DDL: create stored procedures under test
```

---

## Prerequisites

| Requirement | Version |
|---|---|
| Java (JDK) | 11 or later |
| Apache Maven | 3.6 or later |
| SQL Server | 2017 or later (local, Docker, or remote) |

### Running SQL Server locally with Docker

```bash
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=Str0ngPass!2024" \
           -p 1433:1433 --name sqlserver \
           -d mcr.microsoft.com/mssql/server:2022-latest
```

---

## Configuration

All connection parameters are read from **environment variables**.  
If a variable is not set, the default shown below is used.

| Variable | Default | Description |
|---|---|---|
| `DB_HOST` | `localhost` | SQL Server hostname or IP |
| `DB_PORT` | `1433` | SQL Server port |
| `DB_NAME` | `TestDB` | Name of the test database |
| `DB_USER` | `sa` | Login username |
| `DB_PASSWORD` | `Str0ngPass!2024` | Login password |

Override them in your shell before running tests:

```bash
export DB_HOST=my-server
export DB_PASSWORD=MySecret!
```

---

## Running the Tests

```bash
# From the unitesting-framework-java/ directory:
mvn test
```

Maven will:
1. Download dependencies (JUnit 5, mssql-jdbc) on the first run.
2. Trigger `DatabaseSetup` automatically before the first test class loads.
3. Execute all 13 tests and print results to the console.
4. Write Surefire XML reports to `target/surefire-reports/`.

---

## File Descriptions

### `pom.xml`

The Maven Project Object Model.  Declares two runtime dependencies:

- **`org.junit.jupiter:junit-jupiter:5.10.2`** – JUnit 5 test engine (replaces pytest).
- **`com.microsoft.sqlserver:mssql-jdbc:12.8.1.jre11`** – Microsoft JDBC driver (replaces pyodbc).

The **Maven Surefire Plugin 3.2.5** is configured to discover and run all JUnit 5 test classes automatically.

---

### `DatabaseSetup.java`

*Replaces `tests/setup_db.py`.*

A one-time bootstrap utility that runs automatically when the first test class is
loaded (via the static initialiser in `BaseTest`).  It performs three steps:

1. **Wait for SQL Server** – polls the `master` database up to 30 times (5-second
   intervals) until a connection is accepted.
2. **Create the test database** – executes `IF NOT EXISTS … CREATE DATABASE` against
   `master` so the test DB is created idempotently.
3. **Execute DDL scripts** – reads `01_create_tables.sql` then
   `02_create_procedures.sql` from the classpath, splits them on `GO` batch
   separators, and executes each batch.

Key method: `DatabaseSetup.setup()`.

---

### `DbUtils.java`

*Replaces `tests/helpers/db_utils.py`.*

A utility class (no instances needed – all methods are `static`) that encapsulates
every database interaction used by the tests.

#### Insert helpers

| Method | Description |
|---|---|
| `insertStagingParent(conn)` | Inserts a row into `dbo.STAGING` and returns the generated `ID`. |
| `insertStagingFolder(conn, stagingId, ...)` | Inserts a row into `dbo.STAGING_FOLDERS`.  Full-parameter and convenience overloads are provided. |
| `insertHashRegistry(conn, entityName, rowHash, ageSeconds)` | Inserts a hash into `dbo.HASH_REGISTRY` backdated by `ageSeconds` to simulate a prior run. |

#### Stored-procedure execution

| Method | Description |
|---|---|
| `execUspDeltaFolders(conn)` | Executes `dbo.USP_DELTA_FOLDERS`. |
| `execUspDeltaMaster(conn)` | Executes `dbo.USP_DELTA_MASTER`. |

#### Query helpers

| Method | Description |
|---|---|
| `getLatestLog(conn[, entityName])` | Returns the newest `SYS_DELTA_LOG` row as a `Map<String, Object>`. |
| `getTargetFoldersCount(conn)` | Row count of `dbo.TARGET_FOLDERS`. |
| `getHashRegistryCount(conn[, entityName])` | Row count in `dbo.HASH_REGISTRY` for a given entity. |
| `getProcessedStagingCount(conn)` | Count of `STAGING_FOLDERS` rows where `Is_Processed = 'Y'`. |
| `getUnprocessedStagingCount(conn)` | Count of `STAGING_FOLDERS` rows where `Is_Processed = 'N'`. |
| `computeFolderHash(conn, ...)` | Computes the SHA2-256 hash exactly as `USP_DELTA_FOLDERS` does, for use in pre-seeding `HASH_REGISTRY`. |
| `getLogCount(conn)` | Total row count of `dbo.SYS_DELTA_LOG`. |

---

### `BaseTest.java`

*Replaces `conftest.py`.*

The abstract base class that every test class extends.

- **Static initialiser** – calls `DatabaseSetup.setup()` and opens a single shared
  `java.sql.Connection` with `autoCommit = true`.  This mirrors the Python
  session-scoped `db_conn` fixture.  `autoCommit = true` ensures that test-setup
  `INSERT` statements are immediately visible to stored procedures, and that the SPs'
  own explicit `BEGIN/COMMIT TRANSACTION` blocks do not nest inside an outer
  transaction.
- **`@BeforeEach cleanTables()`** – deletes all rows from every test table in
  FK-safe order before each test, mirroring the Python autouse `clean_tables`
  fixture.

---

### `TestUspDeltaFolders.java`

*Replaces `test_usp_delta_folders.py`.*

Ten integration tests for `dbo.USP_DELTA_FOLDERS`:

| Test | ID | Scenario |
|---|---|---|
| `testEmptyStagingLogsSuccess` | TC01 | Empty staging table → early-exit, `input_row_count = 0`, `status = SUCCESS` |
| `testSingleNewRowInsertedToTarget` | TC02 | One new row → inserted into `TARGET_FOLDERS` and `HASH_REGISTRY` |
| `testStagingRowMarkedAsProcessed` | TC03 | After a run all staging rows have `Is_Processed = 'Y'` |
| `testDuplicateStagingRowsDeduped` | TC04 | Three identical rows → one `TARGET` insert, `rows_deduped = 2` |
| `testUnchangedRowNotReinserted` | TC05 | Hash pre-exists → `rows_unchanged = 1`, no new `TARGET` row |
| `testOldHashesRetired` | TC06 | Stale hash absent from current batch → deleted, `rows_retired = 1` |
| `testLogCapturesAllMetrics` | TC07 | Mixed batch → all counters correct |
| `testAlreadyProcessedRowsIgnored` | TC08 | `Is_Processed = 'Y'` rows are not re-processed |
| `testMixedNewAndUnchangedRows` | TC09 | 2 new + 1 pre-existing → `rows_upserted = 2`, `rows_unchanged = 1` |
| `testLogEntryRecordsEntityName` | TC10 | `SYS_DELTA_LOG` always records `entity_name = 'FOLDERS'` |

---

### `TestUspDeltaMaster.java`

*Replaces `test_usp_delta_master.py`.*

Three integration tests for `dbo.USP_DELTA_MASTER`:

| Test | ID | Scenario |
|---|---|---|
| `testMasterExecutesWithoutError` | TC01 | Procedure completes without throwing an exception |
| `testMasterContinuesAfterMissingSubProcedures` | TC02 | Non-existent sub-SPs are swallowed by `TRY/CATCH`; master still completes |
| `testMasterTriggersFoldersProcessing` | TC03 | End-to-end: staging data is processed by `USP_DELTA_FOLDERS` when called via master |

---

### `src/test/resources/sql/01_create_tables.sql`

DDL script that (re-)creates all tables needed by the stored procedures:

- `dbo.STAGING` – parent table; holds a generated ID.
- `dbo.STAGING_FOLDERS` – incoming folder records; FK to `STAGING`.
- `dbo.TARGET_FOLDERS` – destination for processed folder records.
- `dbo.HASH_REGISTRY` – stores SHA2-256 row hashes for change detection.
- `dbo.SYS_DELTA_LOG` – audit log; one row per stored-procedure execution.

---

### `src/test/resources/sql/02_create_procedures.sql`

DDL script that (re-)creates the stored procedures under test:

- **`dbo.USP_DELTA_FOLDERS`** – computes hashes, deduplicates, upserts into
  `TARGET_FOLDERS`, retires stale hashes, and writes a metrics row to
  `SYS_DELTA_LOG`.
- **`dbo.USP_DELTA_MASTER`** – orchestrator that calls every entity-level delta SP
  in sequence, wrapping each call in `BEGIN TRY … END CATCH`.

---

### `.gitlab-ci.yml`

CI pipeline definition for GitLab.  A single `sql-unit-tests` job:

1. Starts a **SQL Server 2022** Docker service (`mcr.microsoft.com/mssql/server:2022-latest`).
2. Uses the **`maven:3.9.6-eclipse-temurin-11`** image.
3. Pre-fetches Maven dependencies offline (`mvn dependency:go-offline`).
4. Runs the full test suite (`mvn test`).
5. Publishes Surefire XML as a JUnit report artifact.

---

## Python → Java Migration Reference

| Python (original) | Java (this framework) |
|---|---|
| `pytest` | JUnit 5 (`junit-jupiter`) |
| `pyodbc` | `mssql-jdbc` |
| `requirements.txt` + `pytest.ini` | `pom.xml` |
| `tests/setup_db.py` | `DatabaseSetup.java` |
| `tests/helpers/db_utils.py` | `DbUtils.java` |
| `conftest.py` fixtures | `BaseTest.java` |
| `test_usp_delta_folders.py` | `TestUspDeltaFolders.java` |
| `test_usp_delta_master.py` | `TestUspDeltaMaster.java` |
| `python:3.11-slim` CI image | `maven:3.9.6-eclipse-temurin-11` CI image |
