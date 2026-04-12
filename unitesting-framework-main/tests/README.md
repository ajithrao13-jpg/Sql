# SQL Unit Testing – Python Framework & GitLab CI Pipeline

This directory contains a **Python-based unit testing framework** for the SQL Server stored procedures in this repository.  
Tests run automatically via GitLab CI every time code is pushed.

---

## Repository artefacts tested

| File | Object |
|------|--------|
| `USP_DELTA_FOLDERS.rtf` | `dbo.USP_DELTA_FOLDERS` stored procedure |
| `USP_DELTA_MASTER.rtf`  | `dbo.USP_DELTA_MASTER` stored procedure  |
| `STAGING_FOLDERS.rtf`   | `dbo.STAGING_FOLDERS` table schema       |
| `TARGET_FOLDERS.rtf`    | `dbo.TARGET_FOLDERS` table schema        |
| `HASH_REGISTRY.rtf`     | `dbo.HASH_REGISTRY` table schema         |
| `SYS_DELTA_LOG.rtf`     | `dbo.SYS_DELTA_LOG` table schema         |

---

## Framework layout

```
tests/
├── conftest.py               # Session-scoped DB connection + per-test cleanup fixture
├── setup_db.py               # Bootstrap: create TestDB, run DDL scripts
├── sql/
│   ├── 01_create_tables.sql  # Table DDL (drop-safe, idempotent)
│   └── 02_create_procedures.sql  # Stored procedure DDL
├── helpers/
│   └── db_utils.py           # Reusable DB helper functions
├── test_usp_delta_folders.py # 10 test cases for USP_DELTA_FOLDERS
└── test_usp_delta_master.py  # 3 test cases for USP_DELTA_MASTER
```

---

## Test cases

### `test_usp_delta_folders.py`

| # | Test | What is verified |
|---|------|-----------------|
| TC01 | `test_empty_staging_logs_success` | Empty staging → early-exit, `status=SUCCESS`, all counts=0 |
| TC02 | `test_single_new_row_inserted_to_target` | 1 new row → inserted into TARGET_FOLDERS & HASH_REGISTRY |
| TC03 | `test_staging_row_marked_as_processed` | After run, `Is_Processed` is flipped to `'Y'` |
| TC04 | `test_duplicate_staging_rows_deduped` | 3 identical rows → 1 TARGET insert, `rows_deduped=2` |
| TC05 | `test_unchanged_row_not_reinserted` | Pre-existing hash → `rows_unchanged=1`, no new TARGET insert |
| TC06 | `test_old_hashes_retired` | Hash absent from current batch → deleted, `rows_retired=1` |
| TC07 | `test_log_captures_all_metrics` | Mixed batch → all SYS_DELTA_LOG counters are correct |
| TC08 | `test_already_processed_rows_ignored` | `Is_Processed='Y'` rows are not re-processed |
| TC09 | `test_mixed_new_and_unchanged_rows` | 2 new + 1 unchanged → `rows_upserted=2`, `rows_unchanged=1` |
| TC10 | `test_log_entry_records_entity_name` | Log always carries `entity_name='FOLDERS'` |

### `test_usp_delta_master.py`

| # | Test | What is verified |
|---|------|-----------------|
| TC01 | `test_master_executes_without_error` | Procedure completes without exception |
| TC02 | `test_master_continues_after_missing_sub_procedures` | Non-existent sub-procs are silently ignored (TRY/CATCH) |
| TC03 | `test_master_triggers_folders_processing` | Staging data is processed end-to-end through the master |

---

## Running tests locally

### Prerequisites

1. **SQL Server** – local instance or Docker:
   ```bash
   docker run -e 'ACCEPT_EULA=Y' -e 'SA_PASSWORD=Str0ngPass!2024' \
     -p 1433:1433 --name sqlserver \
     mcr.microsoft.com/mssql/server:2022-latest
   ```

2. **ODBC Driver 18 for SQL Server** – [install guide](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server)

3. **Python 3.9+** with dependencies:
   ```bash
   pip install -r requirements.txt
   ```

### Bootstrap the test database

```bash
python tests/setup_db.py
```

Override defaults with environment variables if needed:

```bash
DB_HOST=localhost DB_PORT=1433 DB_NAME=TestDB DB_USER=sa DB_PASSWORD=Str0ngPass!2024 \
  python tests/setup_db.py
```

### Run the tests

```bash
pytest tests/ -v
```

Generate an HTML report:

```bash
pytest tests/ -v --html=test-report.html --self-contained-html
```

---

## GitLab CI

The pipeline is defined in `.gitlab-ci.yml` at the repository root.  
On every push it:

1. Starts a SQL Server 2022 Docker service.
2. Installs the Microsoft ODBC 18 driver inside the Python runner.
3. Waits for SQL Server to be ready.
4. Calls `python tests/setup_db.py` to create the schema.
5. Runs `pytest` and publishes a JUnit XML report + HTML report as artefacts.
