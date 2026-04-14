# sql-unit-testingrepo

This repository contains **SQL Server stored procedures** and a complete **tSQLt-based automated testing framework** that verifies their behaviour on every code push via GitLab CI.  No Python, Java, or external test runner is required — the entire pipeline is driven by `sqlcmd`.

---

## What problem does this solve?

The repository contains SQL Server stored procedures written in `.rtf` files.  Without automated tests there is no reliable way to know whether a code change breaks existing behaviour.  This project adds a [tSQLt](https://tsqlt.org/) unit testing framework that:

- Spins up a real SQL Server instance in GitLab CI
- Creates all required tables and stored procedures in a `TestDB` test database
- Runs **13 automated tests** (written entirely in T-SQL) covering every major behaviour path
- Publishes a JUnit XML test report as a downloadable artefact

---

## Stored procedures under test

| Procedure | What it does |
|---|---|
| `USP_DELTA_FOLDERS` | Reads unprocessed rows from `STAGING_FOLDERS`, deduplicates them using a SHA-256 hash, inserts new/changed rows into `TARGET_FOLDERS`, retires old records, and logs every metric to `SYS_DELTA_LOG` |
| `USP_DELTA_MASTER` | An orchestrator that calls all entity-level delta procedures (including `USP_DELTA_FOLDERS`) in sequence.  Every call is wrapped in `TRY/CATCH` so a single failure never stops the pipeline |

---

## Repository layout

### Root-level files

| File | Purpose |
|---|---|
| `.gitlab-ci.yml` | GitLab CI pipeline definition – uses `sqlcmd` only, no Python (see [GitLab CI](#gitlab-ci) below) |
| `.gitignore` | Excludes build artefacts and temporary files |

### `tests/sql/` folder — all test logic lives here as T-SQL

| File | Purpose |
|---|---|
| `tests/sql/01_create_tables.sql` | Creates all 5 tables: `STAGING`, `STAGING_FOLDERS`, `TARGET_FOLDERS`, `HASH_REGISTRY`, `SYS_DELTA_LOG` |
| `tests/sql/02_create_procedures.sql` | Creates `USP_DELTA_FOLDERS` and `USP_DELTA_MASTER` in the test database |
| `tests/sql/03_tsqlt_tests_folders.sql` | tSQLt test class `TestUSPDeltaFolders` — 10 test procedures (TC01–TC10) |
| `tests/sql/04_tsqlt_tests_master.sql` | tSQLt test class `TestUSPDeltaMaster` — 3 test procedures (TC01–TC03) |
| `tests/README.md` | Step-by-step instructions for running the tests locally |
| `tests/TEST_CASES.md` | Full test-case documentation: why each test exists, inputs used, and expected outputs |

---

## Test summary

Tests are written as T-SQL stored procedures inside tSQLt test classes.  tSQLt rolls back a savepoint after each test so every test runs in a clean, isolated state.

### `TestUSPDeltaFolders` – 10 test cases

| # | Test procedure | Scenario |
|---|---|---|
| TC01 | `test TC01 - empty staging logs success` | Nothing in staging → SP exits early, logs `SUCCESS` with all counts = 0 |
| TC02 | `test TC02 - single new row inserted to target` | 1 new row → inserted into `TARGET_FOLDERS` and `HASH_REGISTRY` |
| TC03 | `test TC03 - staging row marked as processed` | After the SP runs, `Is_Processed` is flipped to `'Y'` on every staging row |
| TC04 | `test TC04 - duplicate staging rows deduped` | 3 identical rows → only 1 inserted; `rows_deduped = 2` |
| TC05 | `test TC05 - unchanged row not reinserted` | Hash already known from a previous run → `rows_unchanged = 1`, no new `TARGET` row |
| TC06 | `test TC06 - old hashes retired` | A hash present in the registry but absent from the current batch → deleted; `rows_retired = 1` |
| TC07 | `test TC07 - log captures all metrics` | Mixed batch → every counter in `SYS_DELTA_LOG` is exactly correct |
| TC08 | `test TC08 - already processed rows ignored` | Rows already marked `Is_Processed = 'Y'` are completely ignored |
| TC09 | `test TC09 - mixed new and unchanged rows` | 2 new + 1 pre-existing hash → `rows_upserted = 2`, `rows_unchanged = 1` |
| TC10 | `test TC10 - log entry records entity name` | `SYS_DELTA_LOG` always records `entity_name = 'FOLDERS'` |

### `TestUSPDeltaMaster` – 3 test cases

| # | Test procedure | Scenario |
|---|---|---|
| TC01 | `test TC01 - master executes without error` | Master procedure completes without raising an exception |
| TC02 | `test TC02 - master continues after missing sub procedures` | Non-existent sub-procedures are silently ignored via `TRY/CATCH` |
| TC03 | `test TC03 - master triggers folders processing` | Staging data is processed end-to-end through the master |

For full details on each test case (purpose, inputs, and expected outputs) see [`tests/TEST_CASES.md`](tests/TEST_CASES.md).

---

## How it all fits together

```
Your push to GitLab
  │
  ▼
GitLab CI pipeline starts (.gitlab-ci.yml)
  │
  ├─ SQL Server 2022 Docker service starts
  ├─ sqlcmd (mssql-tools18) installed in the runner
  ├─ TestDB created; CLR + TRUSTWORTHY ON enabled (tSQLt requirement)
  ├─ tSQLt downloaded from tsqlt.org and installed via sqlcmd
  ├─ sqlcmd -i tests/sql/01_create_tables.sql
  ├─ sqlcmd -i tests/sql/02_create_procedures.sql
  ├─ sqlcmd -i tests/sql/03_tsqlt_tests_folders.sql
  ├─ sqlcmd -i tests/sql/04_tsqlt_tests_master.sql
  └─ tSQLt.RunAll  ← runs all 13 tests; JUnit XML captured via tSQLt.XmlResultFormatter
       │
       └─ Artefact published: JUnit XML report (test-results.xml)
```

---

## GitLab CI

The pipeline is defined in `.gitlab-ci.yml` at the repository root.  On every push it:

1. Starts a **SQL Server 2022** Docker service (`mcr.microsoft.com/mssql/server:2022-latest`)
2. Installs **`sqlcmd`** (`mssql-tools18`) in the runner — no Python or other runtime needed
3. Polls SQL Server until it accepts connections
4. Creates `TestDB`; enables CLR and `TRUSTWORTHY ON` (required by tSQLt)
5. Downloads and installs tSQLt from [tsqlt.org](https://tsqlt.org/downloads/) via `curl` / `unzip`
6. Loads the schema DDL and tSQLt test classes with `sqlcmd -i`
7. Runs `tSQLt.RunAll` and captures a **JUnit XML report** as an artefact; fails the job if any test fails

```yaml
services:
  - name: mcr.microsoft.com/mssql/server:2022-latest
    alias: sqlserver
    variables:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "Str0ngPass!2024"
```

The `TSQLT_DOWNLOAD_URL` variable points to the official latest release at tsqlt.org and can be overridden via **GitLab CI/CD Settings → Variables** to pin a specific version.

---

## Running tests locally

Follow these steps to run the full test suite on your own machine.

### Step 1 – Start a SQL Server instance

Use Docker to spin up SQL Server 2022 (no local install required):

```bash
docker run \
  -e 'ACCEPT_EULA=Y' \
  -e 'SA_PASSWORD=Str0ngPass!2024' \
  -p 1433:1433 \
  --name sqlserver \
  -d mcr.microsoft.com/mssql/server:2022-latest
```

Wait ~15 seconds for SQL Server to finish starting before proceeding.

### Step 2 – Install sqlcmd

**Ubuntu / Debian**
```bash
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
curl -fsSL https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list \
  | sudo tee /etc/apt/sources.list.d/mssql-release.list
sudo apt-get update
sudo ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev
export PATH="$PATH:/opt/mssql-tools18/bin"
```

**macOS (Homebrew)**
```bash
brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
brew install mssql-tools18
```

**Windows**  
Download and install the latest **sqlcmd** from [aka.ms/sqlcmd](https://aka.ms/sqlcmd).

### Step 3 – Bootstrap the test database and install tSQLt

```bash
# Create database, enable CLR + TRUSTWORTHY ON
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -C -Q "
  CREATE DATABASE [TestDB];
  EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
  EXEC sp_configure 'clr enabled',           1; RECONFIGURE;
  EXEC sp_configure 'clr strict security',   0; RECONFIGURE;
  ALTER DATABASE [TestDB] SET TRUSTWORTHY ON;
"

# Download and install tSQLt
curl -fsSL https://tsqlt.org/downloads/tSQLt.zip \
  -o /tmp/tsqlt.zip
unzip -q /tmp/tsqlt.zip -d /tmp/tsqlt
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -d TestDB -C \
  -i "$(find /tmp/tsqlt -iname 'tSQLt.class.sql' | head -1)"

# Load schema DDL and test classes
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -d TestDB -C -i tests/sql/01_create_tables.sql
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -d TestDB -C -i tests/sql/02_create_procedures.sql
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -d TestDB -C -i tests/sql/03_tsqlt_tests_folders.sql
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -d TestDB -C -i tests/sql/04_tsqlt_tests_master.sql
```

### Step 4 – Run the tests

```bash
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -d TestDB -C \
  -Q "EXEC tSQLt.RunAll"
```

**Run a single test class:**
```bash
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -d TestDB -C \
  -Q "EXEC tSQLt.Run 'TestUSPDeltaFolders'"
```

**Run a single test procedure:**
```bash
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -d TestDB -C \
  -Q "EXEC tSQLt.Run '[TestUSPDeltaFolders].[test TC01 - empty staging logs success]'"
```

### Expected output

All 13 tests should pass:

```
+----------------------+
|Test Execution Summary|
+----------------------+

|No|Test Case Name                                                  |Dur(ms)|Result |
+--+----------------------------------------------------------------+-------+-------+
|1 |[TestUSPDeltaFolders].[test TC01 - empty staging logs success]  |    42 |Success|
|2 |[TestUSPDeltaFolders].[test TC02 - single new row inserted ...]  |    38 |Success|
...
|13|[TestUSPDeltaMaster].[test TC03 - master triggers folders ...]   |    55 |Success|
-----------------------------------------------------------------------------
Test Case Summary: 13 test case(s) executed, 13 succeeded, 0 failed, 0 errored.
```

### Troubleshooting

| Problem | Fix |
|---|---|
| `sqlcmd: command not found` | Install `mssql-tools18` (Step 2) and add `/opt/mssql-tools18/bin` to `$PATH` |
| `Connection refused` on port 1433 | SQL Server container is not running — run `docker ps` and check |
| `Login failed for user 'sa'` | Wrong password — verify `SA_PASSWORD` matches what you passed to `docker run` |
| `Database 'TestDB' does not exist` | Re-run the bootstrap commands in Step 3 |
| `tSQLt is not installed` | Re-run the tSQLt install step in Step 3 |
| `CLR is disabled` | Ensure `sp_configure 'clr enabled', 1` and `RECONFIGURE` were run against the correct database |