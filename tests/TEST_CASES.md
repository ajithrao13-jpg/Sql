# Test Case Documentation

This document explains every automated test case in the suite: **why** it was written, **what data** is fed in, and **what output** is expected.

All tests are tSQLt unit tests — they run against a real SQL Server instance with the actual stored procedures.  tSQLt wraps every test in a `SAVE TRANSACTION` / `ROLLBACK TO SAVEPOINT` so each test starts with a clean, isolated state automatically.

---

## `USP_DELTA_FOLDERS` – 10 Test Cases

`USP_DELTA_FOLDERS` reads unprocessed rows from `STAGING_FOLDERS`, deduplicates them with a SHA-256 hash, upserts new/changed records into `TARGET_FOLDERS`, retires hashes that are no longer present, and writes a detailed metrics row to `SYS_DELTA_LOG`.

---

### TC01 – Empty staging table exits cleanly

**File:** `tests/sql/03_tsqlt_tests_folders.sql` → `[TestUSPDeltaFolders].[test TC01 - empty staging logs success]`

**Why this test exists**  
The very first thing the SP does is check whether there are any unprocessed rows.  If there are none it should exit early without touching any tables and still write a success log.  Without this test a bug that crashes on an empty table would go undetected.

**Input**  
- `STAGING_FOLDERS` is empty (no rows inserted)

**Steps**  
1. Call `USP_DELTA_FOLDERS`
2. Read the latest row from `SYS_DELTA_LOG`

**Expected output**

| Column | Expected value |
|---|---|
| `status` | `SUCCESS` |
| `input_row_count` | `0` |
| `rows_upserted` | `0` |
| `rows_unchanged` | `0` |
| `rows_deduped` | `0` |
| `rows_retired` | `0` |

`TARGET_FOLDERS` and `HASH_REGISTRY` remain empty.

---

### TC02 – Single new row is inserted into TARGET_FOLDERS

**File:** `tests/sql/03_tsqlt_tests_folders.sql` → `[TestUSPDeltaFolders].[test TC02 - single new row inserted to target]`

**Why this test exists**  
This is the **happy-path baseline**.  A brand-new folder record that has never been seen before should be inserted into both `TARGET_FOLDERS` (the production destination) and `HASH_REGISTRY` (so future runs can detect whether it changed).

**Input**  
- 1 row inserted into `STAGING` (the parent record)
- 1 row inserted into `STAGING_FOLDERS` with `Is_Processed = 'N'`

**Steps**  
1. Insert parent + folder staging row
2. Call `USP_DELTA_FOLDERS`
3. Count rows in `TARGET_FOLDERS`, `HASH_REGISTRY`, and `SYS_DELTA_LOG`

**Expected output**

| Check | Expected value |
|---|---|
| `TARGET_FOLDERS` row count | `1` |
| `HASH_REGISTRY` row count | `1` |
| Log `status` | `SUCCESS` |
| Log `input_row_count` | `1` |
| Log `rows_upserted` | `1` |
| Log `rows_unchanged` | `0` |

---

### TC03 – Staging rows are marked as processed after the SP runs

**File:** `tests/sql/03_tsqlt_tests_folders.sql` → `[TestUSPDeltaFolders].[test TC03 - staging row marked as processed]`

**Why this test exists**  
The SP must flip `Is_Processed` from `'N'` to `'Y'` on every row it consumes.  If this flag is not set the next run would re-process the same rows, causing duplicates.

**Input**  
- 1 parent row in `STAGING`
- 2 folder rows in `STAGING_FOLDERS` with `Is_Processed = 'N'`

**Steps**  
1. Verify there are 2 unprocessed rows before the call
2. Call `USP_DELTA_FOLDERS`
3. Check both counts again

**Expected output**

| Check | Before SP | After SP |
|---|---|---|
| Unprocessed rows (`Is_Processed='N'`) | `2` | `0` |
| Processed rows (`Is_Processed='Y'`) | `0` | `2` |

---

### TC04 – Duplicate staging rows are deduplicated

**File:** `tests/sql/03_tsqlt_tests_folders.sql` → `[TestUSPDeltaFolders].[test TC04 - duplicate staging rows deduped]`

**Why this test exists**  
Source systems sometimes send the same record multiple times in a single batch.  The SP should recognise duplicates (identical hash), insert only one copy, and count the extras as "deduped" so the log is accurate.

**Input**  
- 1 parent row in `STAGING`
- **3 identical rows** in `STAGING_FOLDERS` (same `folder_folder_id`, same description)

**Steps**  
1. Insert 3 identical staging rows
2. Call `USP_DELTA_FOLDERS`

**Expected output**

| Check | Expected value |
|---|---|
| `TARGET_FOLDERS` row count | `1` (only the first occurrence) |
| `HASH_REGISTRY` row count | `1` |
| Log `input_row_count` | `3` |
| Log `rows_upserted` | `1` |
| Log `rows_deduped` | `2` |

---

### TC05 – Unchanged row is not re-inserted

**File:** `tests/sql/03_tsqlt_tests_folders.sql` → `[TestUSPDeltaFolders].[test TC05 - unchanged row not reinserted]`

**Why this test exists**  
If a folder record has not changed since the last run, the SP must detect this (the SHA-256 hash already exists in `HASH_REGISTRY`) and skip the insert.  This prevents unnecessary writes and keeps audit logs accurate.

**Input**  
- 1 parent + 1 folder row in staging
- The **same hash pre-inserted** into `HASH_REGISTRY` to simulate a previous run

**Steps**  
1. Compute the SHA-256 hash for the staging row
2. Insert that hash into `HASH_REGISTRY` directly
3. Insert the same folder row into staging
4. Call `USP_DELTA_FOLDERS`

**Expected output**

| Check | Expected value |
|---|---|
| `TARGET_FOLDERS` row count | `0` (no new insert – hash already known) |
| `HASH_REGISTRY` row count | `1` (unchanged) |
| Log `rows_unchanged` | `1` |
| Log `rows_upserted` | `0` |

---

### TC06 – Stale hashes are retired

**File:** `tests/sql/03_tsqlt_tests_folders.sql` → `[TestUSPDeltaFolders].[test TC06 - old hashes retired]`

**Why this test exists**  
If a folder existed in a previous batch but is **absent from the current batch**, its hash in `HASH_REGISTRY` should be deleted ("retired").  This keeps the registry in sync with what is actually coming from the source system.

**Input**  
- A **stale hash** inserted directly into `HASH_REGISTRY` (represents a folder from a prior run that is no longer in the source)
- 1 different, brand-new folder row inserted into staging

**Steps**  
1. Insert stale hash into `HASH_REGISTRY`
2. Insert a new (different) staging folder
3. Call `USP_DELTA_FOLDERS`

**Expected output**

| Check | Expected value |
|---|---|
| `HASH_REGISTRY` row count | `1` (the stale hash removed, the new hash added) |
| Log `rows_retired` | `1` |

---

### TC07 – All log metrics are captured correctly for a mixed batch

**File:** `tests/sql/03_tsqlt_tests_folders.sql` → `[TestUSPDeltaFolders].[test TC07 - log captures all metrics]`

**Why this test exists**  
This is the **comprehensive metrics test**.  It sends a batch that triggers every possible counter simultaneously and asserts that every number in `SYS_DELTA_LOG` is exactly right.

**Input**  
- 1 existing folder (hash pre-seeded → will be counted as *unchanged*)
- 2 genuinely new folders (→ will be *upserted*)
- 1 duplicate of one of the new folders (→ will be *deduped*)

Total: **4 staging rows**

**Steps**  
1. Pre-seed the hash for `EXIST-001` into `HASH_REGISTRY`
2. Insert all 4 staging rows
3. Call `USP_DELTA_FOLDERS`

**Expected output**

| Log column | Expected value | Reason |
|---|---|---|
| `status` | `SUCCESS` | |
| `input_row_count` | `4` | All 4 staging rows read |
| `rows_unchanged` | `1` | `EXIST-001` hash already known |
| `rows_upserted` | `2` | `NEW-001` and `NEW-002` are new |
| `rows_deduped` | `1` | Second copy of `NEW-001` discarded |
| `rows_retired` | `0` | The existing hash is part of the batch, not stale |

---

### TC08 – Already-processed rows are ignored

**File:** `tests/sql/03_tsqlt_tests_folders.sql` → `[TestUSPDeltaFolders].[test TC08 - already processed rows ignored]`

**Why this test exists**  
The SP filters staging rows by `Is_Processed = 'N'`.  Rows already marked `'Y'` must be invisible to the SP so they are never double-counted.

**Input**  
- 2 staging rows with `Is_Processed = 'Y'` (already processed in a previous run)

**Steps**  
1. Insert 2 pre-processed staging rows
2. Call `USP_DELTA_FOLDERS`

**Expected output**

| Check | Expected value |
|---|---|
| Log `status` | `SUCCESS` |
| Log `input_row_count` | `0` (SP sees nothing unprocessed) |
| `TARGET_FOLDERS` row count | `0` |

---

### TC09 – Mixed batch: new rows and unchanged rows are counted separately

**File:** `tests/sql/03_tsqlt_tests_folders.sql` → `[TestUSPDeltaFolders].[test TC09 - mixed new and unchanged rows]`

**Why this test exists**  
Verifies that the SP correctly splits a batch into two buckets – genuinely new records versus records that already exist in the hash registry – and reports each bucket separately.

**Input**  
- 1 folder whose hash is pre-seeded into `HASH_REGISTRY` (→ *unchanged*)
- 2 brand-new folders with no prior hash (→ *upserted*)

Total: **3 staging rows**

**Steps**  
1. Pre-seed the hash for `MIX-KNOWN`
2. Insert all 3 staging rows
3. Call `USP_DELTA_FOLDERS`

**Expected output**

| Check | Expected value |
|---|---|
| `TARGET_FOLDERS` row count | `2` (only the new rows) |
| Log `input_row_count` | `3` |
| Log `rows_upserted` | `2` |
| Log `rows_unchanged` | `1` |

---

### TC10 – Log entry always records the correct entity name

**File:** `tests/sql/03_tsqlt_tests_folders.sql` → `[TestUSPDeltaFolders].[test TC10 - log entry records entity name]`

**Why this test exists**  
`SYS_DELTA_LOG` stores entries for multiple entities.  Every entry written by `USP_DELTA_FOLDERS` must carry `entity_name = 'FOLDERS'` so that downstream reporting can filter by entity.

**Input**  
- Empty staging (SP exits early after writing the log)

**Steps**  
1. Call `USP_DELTA_FOLDERS`
2. Read the latest log entry

**Expected output**

| Log column | Expected value |
|---|---|
| `entity_name` | `FOLDERS` |
| Total log row count | `≥ 1` |

---

## `USP_DELTA_MASTER` – 3 Test Cases

`USP_DELTA_MASTER` is an **orchestrator procedure**.  It calls all entity-level delta procedures (including `USP_DELTA_FOLDERS`) in sequence.  Every sub-call is wrapped in `BEGIN TRY … END CATCH` so that a failure in one procedure does not stop the rest.

---

### TC01 – Master procedure executes without error

**File:** `tests/sql/04_tsqlt_tests_master.sql` → `[TestUSPDeltaMaster].[test TC01 - master executes without error]`

**Why this test exists**  
The most fundamental check: calling `USP_DELTA_MASTER` must not raise an unhandled exception.  If the procedure itself has a syntax error or a structural problem this test will catch it immediately.

**Input**  
- All tables empty

**Steps**  
1. Call `USP_DELTA_MASTER`
2. Confirm no exception is raised (tSQLt will report any unhandled SQL error as a test failure)

**Expected output**  
- No exception raised
- Procedure completes successfully

---

### TC02 – Master continues when sub-procedures do not exist

**File:** `tests/sql/04_tsqlt_tests_master.sql` → `[TestUSPDeltaMaster].[test TC02 - master continues after missing sub procedures]`

**Why this test exists**  
The test database only has `USP_DELTA_FOLDERS`.  All other entity procedures (`USP_DELTA_ASSETS`, `USP_DELTA_USERS`, etc.) do not exist.  The master should silently swallow those "object not found" errors and still complete.  This test proves the `TRY/CATCH` safety net is working and that `USP_DELTA_FOLDERS` ran despite other failures.

**Input**  
- Empty staging tables
- Only `USP_DELTA_FOLDERS` exists in `TestDB` (other sub-procedures are absent)

**Steps**  
1. Call `USP_DELTA_MASTER`
2. Read the latest `SYS_DELTA_LOG` entry filtered to `entity_name = 'FOLDERS'`

**Expected output**

| Check | Expected value |
|---|---|
| No exception raised | ✓ |
| Log entry for `FOLDERS` exists | ✓ |
| Log `status` | `SUCCESS` |

---

### TC03 – Master triggers end-to-end folder processing

**File:** `tests/sql/04_tsqlt_tests_master.sql` → `[TestUSPDeltaMaster].[test TC03 - master triggers folders processing]`

**Why this test exists**  
An end-to-end integration check.  When real staging data exists, calling `USP_DELTA_MASTER` must cause `USP_DELTA_FOLDERS` to process that data and write results into `TARGET_FOLDERS`.  This confirms the full call chain works: master → `USP_DELTA_FOLDERS` → `TARGET_FOLDERS`.

**Input**  
- 1 parent row in `STAGING`
- 2 folder rows in `STAGING_FOLDERS` (`MASTER-F001`, `MASTER-F002`)

**Steps**  
1. Insert the staging data
2. Call `USP_DELTA_MASTER`
3. Count rows in `TARGET_FOLDERS`
4. Read the latest log for `entity_name = 'FOLDERS'`

**Expected output**

| Check | Expected value |
|---|---|
| `TARGET_FOLDERS` row count | `2` |
| Log `status` | `SUCCESS` |
| Log `rows_upserted` | `2` |

---

## Summary table

| # | Test class | Test procedure | Input summary | Key assertion |
|---|---|---|---|---|
| TC-F01 | TestUSPDeltaFolders | `test TC01 - empty staging logs success` | Empty staging | `status=SUCCESS`, all counts=0 |
| TC-F02 | TestUSPDeltaFolders | `test TC02 - single new row inserted to target` | 1 new row | `TARGET` count=1, `rows_upserted`=1 |
| TC-F03 | TestUSPDeltaFolders | `test TC03 - staging row marked as processed` | 2 unprocessed rows | `Is_Processed='Y'` on both after run |
| TC-F04 | TestUSPDeltaFolders | `test TC04 - duplicate staging rows deduped` | 3 identical rows | `rows_deduped`=2, `TARGET` count=1 |
| TC-F05 | TestUSPDeltaFolders | `test TC05 - unchanged row not reinserted` | 1 row + pre-seeded hash | `rows_unchanged`=1, `TARGET` count=0 |
| TC-F06 | TestUSPDeltaFolders | `test TC06 - old hashes retired` | 1 new row + 1 stale hash | `rows_retired`=1 |
| TC-F07 | TestUSPDeltaFolders | `test TC07 - log captures all metrics` | 4 mixed rows | Every log counter is exact |
| TC-F08 | TestUSPDeltaFolders | `test TC08 - already processed rows ignored` | 2 pre-processed rows | `input_row_count`=0, `TARGET` count=0 |
| TC-F09 | TestUSPDeltaFolders | `test TC09 - mixed new and unchanged rows` | 2 new + 1 unchanged | `rows_upserted`=2, `rows_unchanged`=1 |
| TC-F10 | TestUSPDeltaFolders | `test TC10 - log entry records entity name` | Empty staging | `entity_name='FOLDERS'` in log |
| TC-M01 | TestUSPDeltaMaster | `test TC01 - master executes without error` | Empty tables | No exception |
| TC-M02 | TestUSPDeltaMaster | `test TC02 - master continues after missing sub procedures` | Empty staging | `FOLDERS` log=SUCCESS despite missing other SPs |
| TC-M03 | TestUSPDeltaMaster | `test TC03 - master triggers folders processing` | 2 folder rows | `TARGET` count=2, `rows_upserted`=2 |
