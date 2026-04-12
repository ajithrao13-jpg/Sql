package com.delta;

import org.junit.jupiter.api.BeforeEach;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * BaseTest – shared connection and table-cleanup logic for all test classes.
 *
 * Equivalent to the Python {@code conftest.py}:
 *   • The static initialiser block replaces the session-scoped {@code db_conn}
 *     fixture: the database is bootstrapped and a single JDBC connection is
 *     opened once for the entire JVM run.
 *   • {@link #cleanTables()} replaces the autouse {@code clean_tables} fixture:
 *     all test tables are truncated before every individual test method.
 */
public abstract class BaseTest {

    /**
     * Single JDBC connection shared across all test classes.
     * {@code autoCommit=true} mirrors the Python {@code autocommit=True} so
     * that INSERT statements in test setup are immediately visible to the SP
     * and the SP's own explicit transactions do not nest inside an outer one.
     */
    protected static final Connection conn;

    static {
        try {
            DatabaseSetup.setup();
            conn = DriverManager.getConnection(DatabaseSetup.testUrl());
            conn.setAutoCommit(true);
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                try {
                    if (conn != null && !conn.isClosed()) {
                        conn.close();
                    }
                } catch (SQLException ignored) {
                }
            }));
        } catch (Exception e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    /**
     * Delete all rows from every test table before each test.
     * Tables are deleted in child-first order to satisfy FK constraints.
     */
    @BeforeEach
    void cleanTables() throws SQLException {
        try (Statement stmt = conn.createStatement()) {
            stmt.execute("DELETE FROM dbo.STAGING_FOLDERS");
            stmt.execute("DELETE FROM dbo.STAGING");
            stmt.execute("DELETE FROM dbo.TARGET_FOLDERS");
            stmt.execute("DELETE FROM dbo.HASH_REGISTRY");
            stmt.execute("DELETE FROM dbo.SYS_DELTA_LOG");
        }
    }
}
