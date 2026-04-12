package com.delta;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;

/**
 * DbUtils – Reusable helper methods for database interactions in tests.
 *
 * All methods accept a {@link Connection} and operate on the test database.
 * Equivalent to the Python {@code tests/helpers/db_utils.py}.
 */
public class DbUtils {

    // -------------------------------------------------------------------------
    // Insert helpers
    // -------------------------------------------------------------------------

    /** Insert a row into {@code dbo.STAGING} and return its generated ID. */
    public static long insertStagingParent(Connection conn) throws SQLException {
        try (Statement stmt = conn.createStatement()) {
            stmt.execute("INSERT INTO dbo.STAGING DEFAULT VALUES",
                         Statement.RETURN_GENERATED_KEYS);
            try (ResultSet rs = stmt.getGeneratedKeys()) {
                if (rs.next()) {
                    return rs.getLong(1);
                }
            }
        }
        throw new SQLException("Failed to retrieve generated key after INSERT INTO dbo.STAGING");
    }

    /**
     * Insert a row into {@code dbo.STAGING_FOLDERS} with all column values
     * specified explicitly.
     */
    public static void insertStagingFolder(
            Connection conn,
            long stagingId,
            String folderIfUnmodifiedSince,
            String folderFolderId,
            String folderStateCode,
            String folderTypeCode,
            String folderDescription,
            String folderOwnerEntityId,
            String isProcessed) throws SQLException {

        String sql =
            "INSERT INTO dbo.STAGING_FOLDERS "
            + "(folderIfUnmodifiedSince, folderFolderID, folderStateCode, folderTypeCode, "
            + " folderDescription, folderOwnerEntityId, staging_id, Is_Processed) "
            + "VALUES (?, ?, ?, ?, ?, ?, ?, ?)";

        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setObject(1, folderIfUnmodifiedSince);
            ps.setString(2, folderFolderId);
            ps.setString(3, folderStateCode);
            ps.setString(4, folderTypeCode);
            ps.setString(5, folderDescription);
            ps.setString(6, folderOwnerEntityId);
            ps.setLong(7, stagingId);
            ps.setString(8, isProcessed);
            ps.executeUpdate();
        }
    }

    /**
     * Insert a row with a specified {@code folderFolderId} and all other
     * columns at their default test values.
     */
    public static void insertStagingFolder(
            Connection conn, long stagingId, String folderFolderId) throws SQLException {
        insertStagingFolder(
            conn, stagingId, null, folderFolderId,
            "ACTIVE", "TYPE-A", "Test Folder", "ENTITY-001", "N");
    }

    /**
     * Insert a row using the default {@code folderFolderID} ("FOLDER-001").
     */
    public static void insertStagingFolder(
            Connection conn, long stagingId) throws SQLException {
        insertStagingFolder(conn, stagingId, "FOLDER-001");
    }

    /**
     * Insert a hash into {@code dbo.HASH_REGISTRY} with timestamps backdated
     * by {@code ageSeconds} so it appears older than the current SP run.
     */
    public static void insertHashRegistry(
            Connection conn, String entityName, byte[] rowHash, int ageSeconds)
            throws SQLException {
        String sql =
            "INSERT INTO dbo.HASH_REGISTRY "
            + "(entity_name, row_hash, system_datetime, updated_datetime) "
            + "VALUES (?, ?, DATEADD(SECOND, ?, SYSUTCDATETIME()), "
            + "        DATEADD(SECOND, ?, SYSUTCDATETIME()))";

        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setString(1, entityName);
            ps.setBytes(2, rowHash);
            ps.setInt(3, -ageSeconds);
            ps.setInt(4, -ageSeconds);
            ps.executeUpdate();
        }
    }

    // -------------------------------------------------------------------------
    // Execute stored procedures
    // -------------------------------------------------------------------------

    /** Execute {@code dbo.USP_DELTA_FOLDERS}. */
    public static void execUspDeltaFolders(Connection conn) throws SQLException {
        try (Statement stmt = conn.createStatement()) {
            stmt.execute("EXEC dbo.USP_DELTA_FOLDERS");
        }
    }

    /** Execute {@code dbo.USP_DELTA_MASTER}. */
    public static void execUspDeltaMaster(Connection conn) throws SQLException {
        try (Statement stmt = conn.createStatement()) {
            stmt.execute("EXEC dbo.USP_DELTA_MASTER");
        }
    }

    // -------------------------------------------------------------------------
    // Query helpers
    // -------------------------------------------------------------------------

    /**
     * Return the most recent {@code SYS_DELTA_LOG} row for
     * {@code entityName} as a map of column name → value, or {@code null}.
     */
    public static Map<String, Object> getLatestLog(
            Connection conn, String entityName) throws SQLException {
        String sql =
            "SELECT TOP 1 * FROM dbo.SYS_DELTA_LOG "
            + "WHERE entity_name = ? ORDER BY log_id DESC";

        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setString(1, entityName);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    return null;
                }
                ResultSetMetaData meta = rs.getMetaData();
                Map<String, Object> row = new HashMap<>();
                for (int i = 1; i <= meta.getColumnCount(); i++) {
                    row.put(meta.getColumnName(i), rs.getObject(i));
                }
                return row;
            }
        }
    }

    /** Return the most recent log row for entity {@code "FOLDERS"}. */
    public static Map<String, Object> getLatestLog(Connection conn) throws SQLException {
        return getLatestLog(conn, "FOLDERS");
    }

    /** Return the total number of rows in {@code dbo.TARGET_FOLDERS}. */
    public static int getTargetFoldersCount(Connection conn) throws SQLException {
        try (Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT COUNT(*) FROM dbo.TARGET_FOLDERS")) {
            return rs.next() ? rs.getInt(1) : 0;
        }
    }

    /**
     * Return the number of rows in {@code dbo.HASH_REGISTRY} for
     * {@code entityName}.
     */
    public static int getHashRegistryCount(
            Connection conn, String entityName) throws SQLException {
        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT COUNT(*) FROM dbo.HASH_REGISTRY WHERE entity_name = ?")) {
            ps.setString(1, entityName);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getInt(1) : 0;
            }
        }
    }

    /** Return the hash registry count for entity {@code "FOLDERS"}. */
    public static int getHashRegistryCount(Connection conn) throws SQLException {
        return getHashRegistryCount(conn, "FOLDERS");
    }

    /** Return the number of {@code STAGING_FOLDERS} rows where {@code Is_Processed = 'Y'}. */
    public static int getProcessedStagingCount(Connection conn) throws SQLException {
        try (Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery(
                 "SELECT COUNT(*) FROM dbo.STAGING_FOLDERS WHERE Is_Processed = 'Y'")) {
            return rs.next() ? rs.getInt(1) : 0;
        }
    }

    /** Return the number of {@code STAGING_FOLDERS} rows where {@code Is_Processed = 'N'}. */
    public static int getUnprocessedStagingCount(Connection conn) throws SQLException {
        try (Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery(
                 "SELECT COUNT(*) FROM dbo.STAGING_FOLDERS WHERE Is_Processed = 'N'")) {
            return rs.next() ? rs.getInt(1) : 0;
        }
    }

    /**
     * Compute the SHA2-256 hash exactly as {@code USP_DELTA_FOLDERS} does,
     * so test setup can pre-insert matching hashes into {@code HASH_REGISTRY}.
     */
    public static byte[] computeFolderHash(
            Connection conn,
            String folderIfUnmodifiedSince,
            String folderFolderId,
            String folderStateCode,
            String folderTypeCode,
            String folderDescription,
            String folderOwnerEntityId) throws SQLException {

        String sql =
            "SELECT HASHBYTES('SHA2_256', CONVERT(VARBINARY(8000), CONCAT_WS('|', "
            + "ISNULL(?, ''), ISNULL(?, ''), ISNULL(?, ''), "
            + "ISNULL(?, ''), ISNULL(?, ''), ISNULL(?, ''))))";

        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setObject(1, folderIfUnmodifiedSince);
            ps.setObject(2, folderFolderId);
            ps.setObject(3, folderStateCode);
            ps.setObject(4, folderTypeCode);
            ps.setObject(5, folderDescription);
            ps.setObject(6, folderOwnerEntityId);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getBytes(1) : null;
            }
        }
    }

    /** Return the total number of rows in {@code dbo.SYS_DELTA_LOG}. */
    public static int getLogCount(Connection conn) throws SQLException {
        try (Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT COUNT(*) FROM dbo.SYS_DELTA_LOG")) {
            return rs.next() ? rs.getInt(1) : 0;
        }
    }
}
