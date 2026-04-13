# sql-unit-testingrepo

This repository contains **SQL Server stored procedures** and a complete **Python-based automated testing framework** that verifies their behaviour on every code push via GitLab CI.

---

## What problem does this solve?

The repository contains SQL Server stored procedures written in `.rtf` files.  Without automated tests there is no reliable way to know whether a code change breaks existing behaviour.  This project adds a pytest-based integration test framework that:

- Spins up a real SQL Server instance in GitLab CI
- Creates all required tables and stored procedures in a `TestDB` test database
- Runs **13 automated tests** covering every major behaviour path
- Publishes a JUnit XML + HTML test report as a downloadable artefact

---

## Stored procedures under test

| Procedure | What it does |
|---|---|
| `USP_DELTA_FOLDERS` | Reads unprocessed rows from `STAGING_FOLDERS`, deduplicates them using a SHA-256 hash, inserts new/changed rows into `TARGET_FOLDERS`, retires old records, and logs every metric to `SYS_DELTA_LOG` |
| `USP_DELTA_MASTER` | An orchestrator that calls all entity-level delta procedures (including `USP_DELTA_FOLDERS`) in sequence.  Every call is wrapped in `TRY/CATCH` so a single failure never stops the pipeline |

---

## Files added by this framework

### Root-level files

| File | Purpose |
|---|---|
| `requirements.txt` | Python packages needed: `pyodbc` (SQL Server driver), `pytest` (test runner), `pytest-html` (HTML reports) |
| `pytest.ini` | Tells pytest to discover tests inside the `tests/` folder |
| `.gitlab-ci.yml` | GitLab CI pipeline definition (see [GitLab CI](#gitlab-ci) below) |

### `tests/` folder

| File | Purpose |
|---|---|
| `tests/setup_db.py` | One-time bootstrap script: waits for SQL Server to start, creates `TestDB`, runs all DDL scripts |
| `tests/conftest.py` | Shared pytest fixtures: one session-scoped database connection (`autocommit=True`) + an autouse fixture that wipes all table data before every test |
| `tests/sql/01_create_tables.sql` | Creates all 5 tables: `STAGING`, `STAGING_FOLDERS`, `TARGET_FOLDERS`, `HASH_REGISTRY`, `SYS_DELTA_LOG` |
| `tests/sql/02_create_procedures.sql` | Creates `USP_DELTA_FOLDERS` and `USP_DELTA_MASTER` in the test database |
| `tests/helpers/db_utils.py` | Reusable helper functions used by the tests (insert rows, call procedures, query counts, compute hashes) |
| `tests/test_usp_delta_folders.py` | **10 test cases** for `USP_DELTA_FOLDERS` |
| `tests/test_usp_delta_master.py` | **3 test cases** for `USP_DELTA_MASTER` |
| `tests/README.md` | Step-by-step instructions for running the tests locally |
| `tests/TEST_CASES.md` | Full test-case documentation: why each test exists, inputs used, and expected outputs |

---

## Test summary

### `USP_DELTA_FOLDERS` – 10 test cases

| # | Test name | Scenario |
|---|---|---|
| TC01 | `test_empty_staging_logs_success` | Nothing in staging → SP exits early, logs `SUCCESS` with all counts = 0 |
| TC02 | `test_single_new_row_inserted_to_target` | 1 new row → inserted into `TARGET_FOLDERS` and `HASH_REGISTRY` |
| TC03 | `test_staging_row_marked_as_processed` | After the SP runs, `Is_Processed` is flipped to `'Y'` on every staging row |
| TC04 | `test_duplicate_staging_rows_deduped` | 3 identical rows → only 1 inserted; `rows_deduped = 2` |
| TC05 | `test_unchanged_row_not_reinserted` | Hash already known from a previous run → `rows_unchanged = 1`, no new `TARGET` row |
| TC06 | `test_old_hashes_retired` | A hash present in the registry but absent from the current batch → deleted; `rows_retired = 1` |
| TC07 | `test_log_captures_all_metrics` | Mixed batch → every counter in `SYS_DELTA_LOG` is exactly correct |
| TC08 | `test_already_processed_rows_ignored` | Rows already marked `Is_Processed = 'Y'` are completely ignored |
| TC09 | `test_mixed_new_and_unchanged_rows` | 2 new + 1 pre-existing hash → `rows_upserted = 2`, `rows_unchanged = 1` |
| TC10 | `test_log_entry_records_entity_name` | `SYS_DELTA_LOG` always records `entity_name = 'FOLDERS'` |

### `USP_DELTA_MASTER` – 3 test cases

| # | Test name | Scenario |
|---|---|---|
| TC01 | `test_master_executes_without_error` | Master procedure completes without raising an exception |
| TC02 | `test_master_continues_after_missing_sub_procedures` | Non-existent sub-procedures are silently ignored via `TRY/CATCH` |
| TC03 | `test_master_triggers_folders_processing` | Staging data is processed end-to-end through the master |

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
  ├─ Microsoft ODBC Driver 18 installed in the Python runner
  ├─ pip install -r requirements.txt
  ├─ python tests/setup_db.py   ← creates TestDB, all tables, both procedures
  └─ pytest tests/ -v           ← runs all 13 tests
       │
       └─ Artefacts published: JUnit XML + HTML report
```

---

## GitLab CI

The pipeline is defined in `.gitlab-ci.yml` at the repository root.  On every push it:

1. Starts a **SQL Server 2022** Docker service (`mcr.microsoft.com/mssql/server:2022-latest`)
2. Installs the **Microsoft ODBC 18 driver** inside the Python runner
3. Waits for SQL Server to be ready (polls with `sqlcmd`)
4. Runs `python tests/setup_db.py` to create the schema
5. Runs `pytest` and publishes a **JUnit XML report** + **HTML report** as artefacts

```yaml
services:
  - name: mcr.microsoft.com/mssql/server:2022-latest
    alias: sqlserver
    variables:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "Str0ngPass!2024"
```

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

### Step 2 – Install the Microsoft ODBC Driver 18

Python talks to SQL Server via the ODBC driver.  Choose your operating system:

**Ubuntu / Debian**
```bash
curl https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -
curl https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list \
  | sudo tee /etc/apt/sources.list.d/mssql-release.list
sudo apt-get update
sudo ACCEPT_EULA=Y apt-get install -y msodbcsql18 unixodbc-dev
```

**macOS (Homebrew)**
```bash
brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
brew install msodbcsql18
```

**Windows (Git Bash / PowerShell / CMD)**

1. Download the installer directly:  
   👉 **[msodbcsql.msi (64-bit) – ODBC Driver 18 for SQL Server](https://go.microsoft.com/fwlink/?linkid=2249004)**  
   *(If that link expires, search "Download ODBC Driver for SQL Server" on [learn.microsoft.com](https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server).)*

2. Run the downloaded `.msi` file and follow the installer wizard (accept the licence agreement, keep all defaults).

3. After installation, open a **new** terminal (Git Bash, PowerShell, or CMD) and verify the driver is registered:
   ```powershell
   # PowerShell – should print "ODBC Driver 18 for SQL Server"
   Get-OdbcDriver -Name "ODBC Driver 18 for SQL Server" | Select-Object Name
   ```
   Or in Git Bash / CMD:
   ```bash
   # Should print lines containing "ODBC Driver 18 for SQL Server"
   reg query "HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers"
   ```
   If you see `ODBC Driver 18 for SQL Server` in the output the driver is correctly installed and `setup_db.py` will work.

### Step 3 – Clone the repository and install Python dependencies

```bash
git clone <your-repo-url>
cd sql-unit-testingrepo
pip install -r requirements.txt
```

> **Python 3.9 or later** is required.

### Step 4 – Bootstrap the test database

This creates the `TestDB` database, all tables, and both stored procedures:

```bash
python tests/setup_db.py
```

You can override any connection setting with environment variables:

```bash
DB_HOST=localhost \
DB_PORT=1433 \
DB_NAME=TestDB \
DB_USER=sa \
DB_PASSWORD=Str0ngPass!2024 \
  python tests/setup_db.py
```

### Step 5 – Run the tests

**Basic run (plain text output):**
```bash
pytest tests/ -v
```

**With an HTML report** (opens `test-report.html` in your browser):
```bash
pytest tests/ -v --html=test-report.html --self-contained-html
```

**Run a single test file:**
```bash
pytest tests/test_usp_delta_folders.py -v
```

**Run one specific test:**
```bash
pytest tests/test_usp_delta_folders.py::TestUSPDeltaFolders::test_single_new_row_inserted_to_target -v
```

### Expected output

All 13 tests should pass:

```
tests/test_usp_delta_folders.py::TestUSPDeltaFolders::test_empty_staging_logs_success        PASSED
tests/test_usp_delta_folders.py::TestUSPDeltaFolders::test_single_new_row_inserted_to_target PASSED
tests/test_usp_delta_folders.py::TestUSPDeltaFolders::test_staging_row_marked_as_processed   PASSED
tests/test_usp_delta_folders.py::TestUSPDeltaFolders::test_duplicate_staging_rows_deduped    PASSED
tests/test_usp_delta_folders.py::TestUSPDeltaFolders::test_unchanged_row_not_reinserted      PASSED
tests/test_usp_delta_folders.py::TestUSPDeltaFolders::test_old_hashes_retired                PASSED
tests/test_usp_delta_folders.py::TestUSPDeltaFolders::test_log_captures_all_metrics          PASSED
tests/test_usp_delta_folders.py::TestUSPDeltaFolders::test_already_processed_rows_ignored    PASSED
tests/test_usp_delta_folders.py::TestUSPDeltaFolders::test_mixed_new_and_unchanged_rows      PASSED
tests/test_usp_delta_folders.py::TestUSPDeltaFolders::test_log_entry_records_entity_name     PASSED
tests/test_usp_delta_master.py::TestUSPDeltaMaster::test_master_executes_without_error                       PASSED
tests/test_usp_delta_master.py::TestUSPDeltaMaster::test_master_continues_after_missing_sub_procedures       PASSED
tests/test_usp_delta_master.py::TestUSPDeltaMaster::test_master_triggers_folders_processing                  PASSED

13 passed in Xs
```

### Troubleshooting

| Problem | Fix |
|---|---|
| `pyodbc.InterfaceError: ('IM002', ...)` – Windows | ODBC Driver 18 is not installed. Follow **Step 2 → Windows** above: download and run `msodbcsql.msi`, then open a **new** terminal before re-running `setup_db.py` |
| `pyodbc.InterfaceError: ('IM002', ...)` – Linux/macOS | ODBC Driver 18 is not installed. Follow **Step 2** for your OS above |
| `Connection refused` on port 1433 | SQL Server container is not running – run `docker ps` and check |
| `Login failed for user 'sa'` | Wrong password – verify `SA_PASSWORD` matches what you passed to `docker run` |
| `Database 'TestDB' does not exist` | Run `python tests/setup_db.py` again (Step 4) |
| Tests fail after a partial run | The `clean_tables` fixture resets state automatically; just re-run `pytest` |