# SQL Unit Testing – tSQLt Framework & GitLab CI Pipeline

This directory contains a **tSQLt-based unit testing framework** for the SQL Server stored procedures in this repository.  
Tests are written entirely in T-SQL and run automatically via GitLab CI on every push.  No Python, Java, or external test runner is required.

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
└── sql/
    ├── 01_create_tables.sql          # Table DDL (drop-safe, idempotent)
    ├── 02_create_procedures.sql      # Stored procedure DDL
    ├── 03_tsqlt_tests_folders.sql    # tSQLt test class: TestUSPDeltaFolders (TC01–TC10)
    └── 04_tsqlt_tests_master.sql     # tSQLt test class: TestUSPDeltaMaster  (TC01–TC03)
```

Each test is a T-SQL stored procedure inside a tSQLt test class.  tSQLt wraps every test in a `SAVE TRANSACTION` / `ROLLBACK TO SAVEPOINT` so each test starts with a clean, isolated state — no cleanup code needed.

---

## Test cases

### `TestUSPDeltaFolders` (03_tsqlt_tests_folders.sql)

| # | Test procedure | What is verified |
|---|----------------|-----------------|
| TC01 | `test TC01 - empty staging logs success` | Empty staging → early-exit, `status=SUCCESS`, all counts=0 |
| TC02 | `test TC02 - single new row inserted to target` | 1 new row → inserted into TARGET_FOLDERS & HASH_REGISTRY |
| TC03 | `test TC03 - staging row marked as processed` | After run, `Is_Processed` is flipped to `'Y'` |
| TC04 | `test TC04 - duplicate staging rows deduped` | 3 identical rows → 1 TARGET insert, `rows_deduped=2` |
| TC05 | `test TC05 - unchanged row not reinserted` | Pre-existing hash → `rows_unchanged=1`, no new TARGET insert |
| TC06 | `test TC06 - old hashes retired` | Hash absent from current batch → deleted, `rows_retired=1` |
| TC07 | `test TC07 - log captures all metrics` | Mixed batch → all SYS_DELTA_LOG counters are correct |
| TC08 | `test TC08 - already processed rows ignored` | `Is_Processed='Y'` rows are not re-processed |
| TC09 | `test TC09 - mixed new and unchanged rows` | 2 new + 1 unchanged → `rows_upserted=2`, `rows_unchanged=1` |
| TC10 | `test TC10 - log entry records entity name` | Log always carries `entity_name='FOLDERS'` |

### `TestUSPDeltaMaster` (04_tsqlt_tests_master.sql)

| # | Test procedure | What is verified |
|---|----------------|-----------------|
| TC01 | `test TC01 - master executes without error` | Procedure completes without exception |
| TC02 | `test TC02 - master continues after missing sub procedures` | Non-existent sub-procs are silently ignored (TRY/CATCH) |
| TC03 | `test TC03 - master triggers folders processing` | Staging data is processed end-to-end through the master |

---

## Running tests locally

### Prerequisites

1. **SQL Server** – local instance or Docker:
   ```bash
   docker run -e 'ACCEPT_EULA=Y' -e 'SA_PASSWORD=Str0ngPass!2024' \
     -p 1433:1433 --name sqlserver \
     mcr.microsoft.com/mssql/server:2022-latest
   ```

2. **sqlcmd** (mssql-tools18) — [install guide](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility)

### Bootstrap the test database

```bash
# Create database; enable CLR + TRUSTWORTHY ON (required by tSQLt)
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -C -Q "
  CREATE DATABASE [TestDB];
  EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
  EXEC sp_configure 'clr enabled',           1; RECONFIGURE;
  EXEC sp_configure 'clr strict security',   0; RECONFIGURE;
  ALTER DATABASE [TestDB] SET TRUSTWORTHY ON;
"

# Download and install tSQLt
curl -fsSL https://github.com/tSQLt-org/tSQLt/releases/download/v1.0.8317.15834/tSQLt.zip \
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

### Run the tests

**All tests:**
```bash
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -d TestDB -C \
  -Q "EXEC tSQLt.RunAll"
```

**A single test class:**
```bash
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -d TestDB -C \
  -Q "EXEC tSQLt.Run 'TestUSPDeltaFolders'"
```

**A single test procedure:**
```bash
sqlcmd -S localhost,1433 -U sa -P 'Str0ngPass!2024' -d TestDB -C \
  -Q "EXEC tSQLt.Run '[TestUSPDeltaFolders].[test TC01 - empty staging logs success]'"
```

---

## GitLab CI

The pipeline is defined in `.gitlab-ci.yml` at the repository root.  
On every push it:

1. Starts a SQL Server 2022 Docker service.
2. Installs `sqlcmd` (`mssql-tools18`) in the runner image — **no Python or other runtime needed**.
3. Waits for SQL Server to be ready.
4. Creates `TestDB`; enables CLR + `TRUSTWORTHY ON`.
5. Downloads and installs tSQLt; loads the schema DDL and test classes with `sqlcmd -i`.
6. Runs `tSQLt.RunAll` and publishes a JUnit XML report as an artefact; fails on any test failure.
