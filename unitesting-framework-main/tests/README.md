# SQL Unit Testing – SQL-Driven Framework & GitLab CI Pipeline

This directory contains a **SQL-driven unit testing framework** for the SQL Server stored procedures in this repository.  
Tests run automatically via GitLab CI on every merge request.

> **Developer workflow:** write test cases in `.sql` files — no Python required.  
> Python only *runs* the SQL and generates the report.

---

## 🐳 Easiest way – Docker web UI (recommended for local development)

No Python, no ODBC drivers, no manual setup — just Docker.

```bash
# From the unitesting-framework-main/ directory:
docker compose up --build
```

Then open **http://localhost:5000** in your browser.

| What you see | What to do |
|---|---|
| Dashboard page | Click **Run Unit Tests** |
| Results table | View PASS / FAIL per test case |
| Download buttons | Save the **HTML Report** or **JUnit XML** locally |

### Adding or editing test cases

1. Stop the app: `Ctrl+C` then `docker compose down`
2. Edit (or add) `.sql` files in `tests/sql/testcases/`
3. Start again: `docker compose up`
4. Click **Run Unit Tests** — new tests are picked up automatically

> The `tests/sql/testcases/` folder is mounted as a volume.  
> **No Docker image rebuild is needed** when you only change `.sql` files.

---

## Manual Quick Start – Run tests in 4 steps

```
Step 1 │ Start SQL Server
Step 2 │ Install Python dependencies
Step 3 │ Bootstrap the test database
Step 4 │ Run pytest
```

### Step 1 – Start SQL Server

Use Docker (recommended for local development):

```bash
docker run \
  -e 'ACCEPT_EULA=Y' \
  -e 'SA_PASSWORD=Str0ngPass!2024' \
  -p 1433:1433 \
  --name sqlserver \
  --rm \
  mcr.microsoft.com/mssql/server:2022-latest
```

> If you already have a SQL Server instance, skip this step and set the environment variables in Step 3.

### Step 2 – Install Python dependencies

From the **repository root** (`unitesting-framework-main/`):

```bash
# Install ODBC Driver 18 (Linux – Debian/Ubuntu)
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor \
  -o /usr/share/keyrings/microsoft-prod.gpg
curl -fsSL https://packages.microsoft.com/config/debian/12/prod.list \
  -o /etc/apt/sources.list.d/mssql-release.list
sudo apt-get update
ACCEPT_EULA=Y sudo apt-get install -y msodbcsql18 unixodbc-dev

# Install Python packages
pip install -r requirements.txt
```

> **macOS / Windows:** follow the [official ODBC Driver 18 install guide](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server) then run `pip install -r requirements.txt`.

### Step 3 – Bootstrap the test database

This creates the `TestDB` database, tables, and stored procedures:

```bash
python tests/setup_db.py
```

To connect to a non-default SQL Server, override the variables:

```bash
DB_HOST=my-server \
DB_PORT=1433 \
DB_NAME=TestDB \
DB_USER=sa \
DB_PASSWORD=Str0ngPass!2024 \
  python tests/setup_db.py
```

### Step 4 – Run the tests

Basic run (verbose output):

```bash
pytest tests/ -v
```

Generate an **HTML report** (opens in any browser):

```bash
pytest tests/ -v --html=test-report.html --self-contained-html
```

Generate a **JUnit XML report** (for CI integration):

```bash
pytest tests/ --junitxml=test-results.xml
```

Generate **both reports at once**:

```bash
pytest tests/ -v --junitxml=test-results.xml --html=test-report.html --self-contained-html
```

---

## How to add a new test case (SQL only – no Python needed)

1. Open (or create) a `.sql` file in `tests/sql/testcases/`.
2. Write your test using the marker format below.
3. Run `pytest` — your test is discovered automatically.

```sql
-- @@TEST: TC11 - My new scenario
-- @@DESCRIPTION: Brief explanation of what this test verifies

-- Setup: insert any data needed
DECLARE @staging_id BIGINT;
INSERT INTO dbo.STAGING DEFAULT VALUES;
SET @staging_id = SCOPE_IDENTITY();

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'MY-FOLDER', 'ACTIVE', 'TYPE-A', 'My Description', 'ENTITY-001', @staging_id, 'N');

-- Call the stored procedure under test
EXEC dbo.USP_DELTA_FOLDERS;

-- @@ASSERT: TARGET_FOLDERS should have 1 row
SELECT CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END
FROM dbo.TARGET_FOLDERS;

-- @@ASSERT: Log status is SUCCESS
SELECT CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@END_TEST
```

### SQL marker reference

| Marker | Purpose |
|--------|---------|
| `-- @@TEST: <name>` | Start a test case; name appears in the pytest report |
| `-- @@DESCRIPTION: <text>` | Optional one-line description |
| *(SQL between @@TEST and first @@ASSERT)* | Setup DML + `EXEC` stored procedure |
| `-- @@ASSERT: <description>` | Start an assertion; description shown in failure messages |
| *(SELECT after @@ASSERT)* | Must return **1 row, 1 column**: `1` = PASS, `0` = FAIL |
| `-- @@END_TEST` | Close the test case |

**Notes:**
- One `.sql` file can contain any number of test cases.
- All tables are automatically cleaned before each test by the `clean_tables` fixture — tests never affect each other.
- Plain `--` comments inside a test block are treated as normal SQL (no special meaning).

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

## Repository layout

```
unitesting-framework-main/
├── docker-compose.yml                # 🐳 Local web UI – just run `docker compose up`
├── Dockerfile                        # Python + ODBC Driver 18 image for the web app
├── .gitlab-ci.yml                    # GitLab CI pipeline definition
├── pytest.ini                        # pytest configuration
├── requirements.txt                  # Core Python dependencies (pyodbc, pytest, pytest-html)
├── requirements-web.txt              # Web app dependency (flask)
│
├── webapp/                           # ← Docker web application
│   ├── app.py                        # Flask backend: runs tests, serves results & downloads
│   └── templates/
│       └── index.html                # Browser UI (Run button, results table, download links)
│
├── tests/                            # ← Active test framework
│   ├── conftest.py                   # DB connection fixture + per-test table cleanup
│   ├── setup_db.py                   # Bootstrap: creates TestDB + runs DDL scripts
│   ├── test_sql_runner.py            # pytest runner – discovers & runs SQL test cases
│   ├── helpers/
│   │   ├── __init__.py
│   │   └── sql_test_parser.py        # Parses @@TEST / @@ASSERT / @@END_TEST markers
│   └── sql/
│       ├── 01_create_tables.sql      # Table DDL (drop-safe, idempotent)
│       ├── 02_create_procedures.sql  # Stored procedure DDL
│       └── testcases/               ← ADD YOUR TEST CASES HERE (.sql files)
│           ├── test_usp_delta_folders.sql   # 10 test cases for USP_DELTA_FOLDERS
│           └── test_usp_delta_master.sql    # 3 test cases for USP_DELTA_MASTER
│
└── test-code/                        # ← Legacy / archived (not used by active tests)
    ├── README.md
    ├── db_utils.py                   # Old Python DB helper functions (archived)
    └── TEST_CASES.md                 # Old Python test-case documentation (archived)
```

---

## Test cases

### `tests/sql/testcases/test_usp_delta_folders.sql`

| # | Test | What is verified |
|---|------|-----------------|
| TC01 | Empty staging table logs success | Empty staging → early-exit, `status=SUCCESS`, all counts=0 |
| TC02 | Single new row inserted to target | 1 new row → inserted into TARGET_FOLDERS & HASH_REGISTRY |
| TC03 | Staging row marked as processed after SP run | After run, `Is_Processed` is flipped to `'Y'` |
| TC04 | Duplicate staging rows are deduplicated | 3 identical rows → 1 TARGET insert, `rows_deduped=2` |
| TC05 | Unchanged row with pre-existing hash is not reinserted | Pre-existing hash → `rows_unchanged=1`, no new TARGET insert |
| TC06 | Old hashes not in current batch are retired | Hash absent from current batch → deleted, `rows_retired=1` |
| TC07 | All metrics captured correctly in a mixed multi-row batch | Mixed batch → all SYS_DELTA_LOG counters are correct |
| TC08 | Already-processed rows are ignored by the SP | `Is_Processed='Y'` rows are not re-processed |
| TC09 | Mixed batch with new and unchanged rows | 2 new + 1 unchanged → `rows_upserted=2`, `rows_unchanged=1` |
| TC10 | Log entry always records the correct entity name | Log always carries `entity_name='FOLDERS'` |

### `tests/sql/testcases/test_usp_delta_master.sql`

| # | Test | What is verified |
|---|------|-----------------|
| TC01 | Master procedure executes without error | Procedure completes without exception |
| TC02 | Sub-procedure failures do not stop the master | Non-existent sub-procs are silently ignored (TRY/CATCH) |
| TC03 | Master delegates to USP_DELTA_FOLDERS end-to-end | Staging data is processed end-to-end through the master |

---

## GitLab CI

The pipeline (`.gitlab-ci.yml`) runs automatically on every merge request:

| Step | What happens |
|------|-------------|
| 1 | SQL Server 2022 Docker service starts |
| 2 | Microsoft ODBC 18 Driver is installed in the Python runner |
| 3 | SQL Server readiness is polled (`setup_db.py` retries up to 30×) |
| 4 | `python tests/setup_db.py` creates `TestDB`, tables, and stored procedures |
| 5 | `pytest` runs all `.sql` test cases via `test_sql_runner.py` |
| 6 | `test-results.xml` (JUnit) published to the GitLab MR test tab |
| 7 | `test-report.html` (pytest-html) saved as a downloadable artefact (30-day retention) |

### Viewing CI results

- **GitLab MR → Tests tab** – pass/fail counts per test case
- **GitLab MR → Artefacts → `test-report.html`** – download and open in a browser for full detail
