# Legacy / Unused Code

This folder contains code and documentation that was part of the **original Python-based test approach**.  
It is kept here for reference only and is **not used** by the current SQL-driven test framework.

## Contents

| File | Why archived |
|------|-------------|
| `db_utils.py` | Python helper functions (INSERT/EXEC/query wrappers) used by the old `test_usp_delta_folders.py` and `test_usp_delta_master.py`. These Python test files were replaced by `.sql` test case files. |
| `TEST_CASES.md` | Detailed test-case documentation written for the old Python test files. Test intent is now documented inline in the `.sql` test case files with `-- @@DESCRIPTION:` comments. |

## Why they were moved

The framework was upgraded so that developers write test cases entirely in `.sql` files.  
Python now only *runs* the SQL and generates reports — the `db_utils.py` functions are no longer called.

If you need to understand the old approach before the SQL-driven upgrade, refer to the files here.
