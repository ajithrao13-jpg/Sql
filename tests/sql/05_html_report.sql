-- =============================================================================
-- 05_html_report.sql
-- Creates a stored procedure that reads tSQLt.TestResult and outputs a
-- self-contained, styled HTML report.
--
-- Usage (from the CI pipeline / locally):
--   sqlcmd -S <host>,<port> -U sa -P <pwd> -d <db> -C -h -1 -y 0 \
--          -Q "SET NOCOUNT ON; EXEC dbo.USP_TSQLT_HTML_REPORT" \
--     | sed '/^[[:space:]]*$/d' > test-results.html
--
-- The procedure must be created BEFORE running tests, but called AFTER
-- tSQLt.RunAll has populated tSQLt.TestResult.
-- =============================================================================

CREATE OR ALTER PROCEDURE dbo.USP_TSQLT_HTML_REPORT
AS
BEGIN
    SET NOCOUNT ON;

    -- ── Aggregate counters ────────────────────────────────────────────────────
    DECLARE @total   INT = 0,
            @passed  INT = 0,
            @failed  INT = 0,
            @errored INT = 0;

    SELECT
        @total   = COUNT(*),
        @passed  = SUM(CASE WHEN Result = 'Success' THEN 1 ELSE 0 END),
        @failed  = SUM(CASE WHEN Result = 'Failure' THEN 1 ELSE 0 END),
        @errored = SUM(CASE WHEN Result = 'Error'   THEN 1 ELSE 0 END)
    FROM tSQLt.TestResult;

    -- ── Build table rows via cursor (avoids FOR XML entity-encoding issues) ───
    DECLARE @rows NVARCHAR(MAX) = N'';
    DECLARE @testName NVARCHAR(MAX),
            @result   NVARCHAR(MAX),
            @msg      NVARCHAR(MAX);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT TestCaseName,
               Result,
               ISNULL(CAST(Msg AS NVARCHAR(MAX)), N'')
        FROM   tSQLt.TestResult
        ORDER  BY TestCaseName;

    OPEN cur;
    FETCH NEXT FROM cur INTO @testName, @result, @msg;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- HTML-encode the three user-supplied values
        SET @testName = REPLACE(REPLACE(REPLACE(@testName, N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;');
        SET @msg      = REPLACE(REPLACE(REPLACE(@msg,      N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;');

        SET @rows = @rows +
            N'<tr class="' +
                CASE @result WHEN 'Success' THEN N'pass' ELSE N'fail' END +
            N'">' +
            N'<td>' + @testName + N'</td>' +
            N'<td class="result">' + @result + N'</td>' +
            N'<td>' + @msg + N'</td>' +
            N'</tr>' + NCHAR(10);

        FETCH NEXT FROM cur INTO @testName, @result, @msg;
    END;

    CLOSE cur;
    DEALLOCATE cur;

    -- ── Assemble the full HTML page ───────────────────────────────────────────
    DECLARE @runDate NVARCHAR(30) = CONVERT(NVARCHAR(30), GETUTCDATE(), 120);
    DECLARE @overallClass NVARCHAR(10) =
        CASE WHEN @failed + @errored = 0 THEN N'pass' ELSE N'fail' END;

    DECLARE @html NVARCHAR(MAX) =
        N'<!DOCTYPE html>' + NCHAR(10) +
        N'<html lang="en">' + NCHAR(10) +
        N'<head>' + NCHAR(10) +
        N'<meta charset="utf-8">' + NCHAR(10) +
        N'<meta name="viewport" content="width=device-width,initial-scale=1">' + NCHAR(10) +
        N'<title>tSQLt Test Report</title>' + NCHAR(10) +
        N'<style>' + NCHAR(10) +
        N'*{box-sizing:border-box;margin:0;padding:0}' + NCHAR(10) +
        N'body{font-family:Arial,Helvetica,sans-serif;background:#f0f2f5;color:#333;padding:24px}' + NCHAR(10) +
        N'h1{font-size:1.6rem;margin-bottom:4px}' + NCHAR(10) +
        N'.subtitle{color:#666;font-size:.9rem;margin-bottom:20px}' + NCHAR(10) +
        N'.summary{display:flex;gap:16px;flex-wrap:wrap;margin-bottom:24px}' + NCHAR(10) +
        N'.badge{padding:12px 22px;border-radius:6px;color:#fff;font-size:1.1rem;font-weight:bold;min-width:120px;text-align:center}' + NCHAR(10) +
        N'.badge.total{background:#495057}' + NCHAR(10) +
        N'.badge.pass{background:#28a745}' + NCHAR(10) +
        N'.badge.fail{background:#dc3545}' + NCHAR(10) +
        N'.overall{display:inline-block;padding:4px 14px;border-radius:4px;font-weight:bold;font-size:.9rem;margin-bottom:20px}' + NCHAR(10) +
        N'.overall.pass{background:#d4edda;color:#155724;border:1px solid #c3e6cb}' + NCHAR(10) +
        N'.overall.fail{background:#f8d7da;color:#721c24;border:1px solid #f5c6cb}' + NCHAR(10) +
        N'table{width:100%;border-collapse:collapse;background:#fff;border-radius:6px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.1)}' + NCHAR(10) +
        N'thead th{background:#343a40;color:#fff;padding:10px 14px;text-align:left;font-size:.85rem;text-transform:uppercase;letter-spacing:.05em}' + NCHAR(10) +
        N'tbody tr{border-bottom:1px solid #e9ecef}' + NCHAR(10) +
        N'tbody tr:last-child{border-bottom:none}' + NCHAR(10) +
        N'td{padding:9px 14px;font-size:.88rem;vertical-align:top}' + NCHAR(10) +
        N'tr.pass td{background:#f6fff8}' + NCHAR(10) +
        N'tr.fail td{background:#fff5f5}' + NCHAR(10) +
        N'td.result{font-weight:bold}' + NCHAR(10) +
        N'tr.pass td.result{color:#28a745}' + NCHAR(10) +
        N'tr.fail td.result{color:#dc3545}' + NCHAR(10) +
        N'</style>' + NCHAR(10) +
        N'</head>' + NCHAR(10) +
        N'<body>' + NCHAR(10) +
        N'<h1>tSQLt Test Report</h1>' + NCHAR(10) +
        N'<p class="subtitle">Generated: ' + @runDate + N' UTC</p>' + NCHAR(10) +
        N'<div class="summary">' + NCHAR(10) +
        N'  <span class="badge total">Total<br>' + CAST(@total AS NVARCHAR(10)) + N'</span>' + NCHAR(10) +
        N'  <span class="badge pass">Passed<br>' + CAST(@passed AS NVARCHAR(10)) + N'</span>' + NCHAR(10) +
        N'  <span class="badge fail">Failed / Error<br>' + CAST(@failed + @errored AS NVARCHAR(10)) + N'</span>' + NCHAR(10) +
        N'</div>' + NCHAR(10) +
        N'<p><span class="overall ' + @overallClass + N'">' +
            CASE WHEN @failed + @errored = 0 THEN N'ALL TESTS PASSED' ELSE N'TESTS FAILED' END +
        N'</span></p>' + NCHAR(10) +
        N'<br>' + NCHAR(10) +
        N'<table>' + NCHAR(10) +
        N'<thead><tr>' +
        N'<th>Test Case</th>' +
        N'<th>Result</th>' +
        N'<th>Message</th>' +
        N'</tr></thead>' + NCHAR(10) +
        N'<tbody>' + NCHAR(10) +
        ISNULL(@rows, N'') +
        N'</tbody>' + NCHAR(10) +
        N'</table>' + NCHAR(10) +
        N'</body>' + NCHAR(10) +
        N'</html>';

    SELECT @html;
END;
GO
