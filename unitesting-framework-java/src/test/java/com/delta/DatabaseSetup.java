package com.delta;

import java.io.BufferedReader;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Arrays;

/**
 * DatabaseSetup – Bootstrap utility executed once before the test suite.
 *
 * Responsibilities:
 *   1. Wait for SQL Server to become available.
 *   2. Create the test database if it does not already exist.
 *   3. Execute DDL scripts (tables then stored procedures) inside the test DB.
 *
 * Equivalent to the Python {@code tests/setup_db.py}.
 */
public class DatabaseSetup {

    static final String DB_HOST     = System.getenv().getOrDefault("DB_HOST",     "localhost");
    static final String DB_PORT     = System.getenv().getOrDefault("DB_PORT",     "1433");
    static final String DB_NAME     = System.getenv().getOrDefault("DB_NAME",     "TestDB");
    static final String DB_USER     = System.getenv().getOrDefault("DB_USER",     "sa");
    static final String DB_PASSWORD = System.getenv().getOrDefault("DB_PASSWORD", "Str0ngPass!2024");

    private static final String MASTER_URL = String.format(
        "jdbc:sqlserver://%s:%s;databaseName=master;user=%s;password=%s;trustServerCertificate=true",
        DB_HOST, DB_PORT, DB_USER, DB_PASSWORD
    );

    static String testUrl() {
        return String.format(
            "jdbc:sqlserver://%s:%s;databaseName=%s;user=%s;password=%s;trustServerCertificate=true",
            DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
        );
    }

    /** Entry point for running setup standalone (e.g. from Maven exec plugin). */
    public static void main(String[] args) throws Exception {
        setup();
    }

    /** Full setup: wait → create DB → execute DDL scripts. */
    public static void setup() throws Exception {
        waitForSqlServer(30, 5);
        createDatabase();
        executeSqlFiles();
        System.out.println("Database setup complete.");
    }

    static void waitForSqlServer(int retries, int delaySeconds) throws InterruptedException {
        System.out.printf("Waiting for SQL Server at %s:%s ...%n", DB_HOST, DB_PORT);
        for (int attempt = 1; attempt <= retries; attempt++) {
            try (Connection ignored = DriverManager.getConnection(MASTER_URL)) {
                System.out.printf("  SQL Server is ready (attempt %d).%n", attempt);
                return;
            } catch (SQLException e) {
                System.out.printf("  Attempt %d/%d failed: %s%n", attempt, retries, e.getMessage());
                Thread.sleep(delaySeconds * 1000L);
            }
        }
        throw new RuntimeException("SQL Server did not become available in time.");
    }

    static void createDatabase() throws SQLException {
        try (Connection conn = DriverManager.getConnection(MASTER_URL);
             Statement stmt = conn.createStatement()) {
            stmt.execute(
                "IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'" + DB_NAME + "') "
                + "    CREATE DATABASE [" + DB_NAME + "];"
            );
        }
        System.out.printf("Database '%s' is ready.%n", DB_NAME);
    }

    static void executeSqlFiles() throws Exception {
        String[] scripts = {"sql/01_create_tables.sql", "sql/02_create_procedures.sql"};
        try (Connection conn = DriverManager.getConnection(testUrl());
             Statement stmt = conn.createStatement()) {
            for (String script : scripts) {
                URL resource = DatabaseSetup.class.getClassLoader().getResource(script);
                if (resource == null) {
                    throw new FileNotFoundException("SQL script not found on classpath: " + script);
                }
                System.out.printf("Executing %s ...%n", script);
                String sql = readResource(resource);
                for (String batch : splitGoBatches(sql)) {
                    stmt.execute(batch);
                }
            }
        }
    }

    static String readResource(URL url) throws IOException {
        try (InputStream in = url.openStream();
             BufferedReader reader = new BufferedReader(
                 new InputStreamReader(in, StandardCharsets.UTF_8))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line).append("\n");
            }
            return sb.toString();
        }
    }

    static String[] splitGoBatches(String sql) {
        return Arrays.stream(sql.split("(?im)^\\s*GO\\s*$"))
                     .map(String::trim)
                     .filter(s -> !s.isEmpty())
                     .toArray(String[]::new);
    }
}
