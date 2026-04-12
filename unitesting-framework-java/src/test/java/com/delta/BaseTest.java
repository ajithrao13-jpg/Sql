package com.delta;

import org.junit.jupiter.api.BeforeEach;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;

/**
 * BaseTest – shared connection and table-cleanup logic for all test classes.
 *
 * Equivalent to the Python {@code conftest.py}:
 *   • The static initialiser block replaces the session-scoped {@code db_conn}
 *     fixture: the database is bootstrapped and a single JDBC connection is
 *     opened once for the entire JVM run.
 *   • {@link #cleanAndReseed()} replaces the autouse {@code clean_tables} fixture:
 *     all test tables are reset to the baseline sample data (via
 *     {@code 03_sample_data.sql}) before every individual test method.
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
     * Reset all test tables to the baseline sample data before each test.
     *
     * {@code 03_sample_data.sql} begins with DELETE statements (FK-safe order)
     * and then re-inserts the standard set of rows, so this single call both
     * cleans and reseeds – giving every test the same predictable starting state.
     */
    @BeforeEach
    void cleanAndReseed() throws Exception {
        DatabaseSetup.loadSampleData();
    }
}
