"""
sql_test_parser.py
==================
Parser for SQL-driven test case files.

File format
-----------
Each .sql file in tests/sql/testcases/ may contain one or more test cases.

Syntax::

    -- @@TEST: TC01 - Short name of the test
    -- @@DESCRIPTION: Optional one-line description (may be omitted)

    <setup SQL: INSERT statements, DECLARE variables, etc.>

    EXEC dbo.USP_MY_PROCEDURE;

    -- @@ASSERT: Human-readable description of what is being checked
    SELECT <expression that returns 1 for PASS or 0 for FAIL>;

    -- @@ASSERT: Another check
    SELECT ...;

    -- @@END_TEST

Rules
-----
- ``@@TEST`` and ``@@END_TEST`` delimit each test case.
- SQL between ``@@TEST`` and the first ``@@ASSERT`` is the *body* (setup + exec).
- Each ``@@ASSERT`` block contains one SELECT statement returning 1 = pass / 0 = fail.
- Multiple test cases per file are supported.
- Plain SQL comments (``--``) that do not start with ``@@`` are treated as SQL.
- GO batch separators inside the body are supported; each batch is executed in order.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import List


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class SqlAssertion:
    """A single assertion within a SQL test case."""

    description: str
    sql: str


@dataclass
class SqlTestCase:
    """A SQL-driven test case parsed from a .sql file."""

    file_name: str          # basename of the source file
    name: str               # from -- @@TEST: <name>
    description: str        # from -- @@DESCRIPTION: <desc>  (may be "")
    body_sql: str           # setup + exec SQL before the first @@ASSERT
    assertions: List[SqlAssertion] = field(default_factory=list)

    @property
    def full_id(self) -> str:
        """Unique ID suitable for pytest parametrize."""
        stem = os.path.splitext(self.file_name)[0]
        safe = re.sub(r"[^a-zA-Z0-9_.-]", "_", self.name)
        return f"{stem}__{safe}"


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def discover_sql_test_cases(directory: str) -> List[SqlTestCase]:
    """Return all SqlTestCase objects found in ``*.sql`` files under *directory*."""
    cases: List[SqlTestCase] = []
    if not os.path.isdir(directory):
        return cases
    for filename in sorted(os.listdir(directory)):
        if filename.lower().endswith(".sql"):
            filepath = os.path.join(directory, filename)
            cases.extend(parse_sql_test_file(filepath))
    return cases


def parse_sql_test_file(filepath: str) -> List[SqlTestCase]:
    """Parse *filepath* and return a list of :class:`SqlTestCase` objects."""
    with open(filepath, encoding="utf-8") as fh:
        content = fh.read()

    file_name = os.path.basename(filepath)
    cases: List[SqlTestCase] = []

    # Match each -- @@TEST: ... -- @@END_TEST block (non-greedy, DOTALL)
    block_re = re.compile(
        r"--\s*@@TEST:\s*(.+?)\n(.*?)--\s*@@END_TEST",
        re.DOTALL | re.IGNORECASE,
    )

    for block in block_re.finditer(content):
        test_name = block.group(1).strip()
        body = block.group(2)

        # Extract optional description
        desc_match = re.search(r"--\s*@@DESCRIPTION:\s*(.+)", body, re.IGNORECASE)
        description = desc_match.group(1).strip() if desc_match else ""

        # Split at first @@ASSERT: marker
        assert_split = re.search(r"--\s*@@ASSERT:", body, re.IGNORECASE)
        if assert_split:
            body_sql = body[: assert_split.start()].strip()
            assert_section = body[assert_split.start():]
        else:
            body_sql = body.strip()
            assert_section = ""

        # Remove the @@DESCRIPTION line from body_sql
        if desc_match:
            body_sql = re.sub(
                r"--\s*@@DESCRIPTION:\s*.+\n?", "", body_sql, flags=re.IGNORECASE
            ).strip()

        assertions = _parse_assertions(assert_section)

        cases.append(
            SqlTestCase(
                file_name=file_name,
                name=test_name,
                description=description,
                body_sql=body_sql,
                assertions=assertions,
            )
        )

    return cases


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _parse_assertions(section: str) -> List[SqlAssertion]:
    """Split *section* on ``@@ASSERT:`` markers and return assertion list."""
    assertions: List[SqlAssertion] = []
    # Split on every -- @@ASSERT: marker; first element is empty (before marker)
    parts = re.split(r"--\s*@@ASSERT:\s*", section, flags=re.IGNORECASE)
    for part in parts[1:]:
        lines = part.split("\n", 1)
        desc = lines[0].strip()
        sql = lines[1].rstrip() if len(lines) > 1 else ""
        if sql.strip():
            assertions.append(SqlAssertion(description=desc, sql=sql))
    return assertions
