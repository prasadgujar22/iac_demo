package com.example.onboarding.util;

import java.sql.Connection;
import java.sql.Driver;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.Properties;

public final class ConnectionManager {
    private ConnectionManager() {
    }

    /**
     * Resolve the JDBC driver class for a URL.
     *
     * In a Java EE container, java.sql.DriverManager is loaded by the SYSTEM
     * classloader, so its ServiceLoader scan of META-INF/services/java.sql.Driver
     * cannot see driver jars packaged inside WEB-INF/lib. Without an explicit
     * Class.forName, DriverManager reports "No suitable driver found" even though
     * the jar is bundled in the WAR.
     */
    private static String driverClassFor(String url) {
        if (url == null) {
            return null;
        }
        if (url.startsWith("jdbc:h2:")) {
            return "org.h2.Driver";
        }
        if (url.startsWith("jdbc:oracle:")) {
            return "oracle.jdbc.OracleDriver";
        }
        return null;
    }

    public static Connection getConnection(DatabaseConfig config) throws SQLException {
        String url = config.getUrl();
        String driverClass = driverClassFor(url);

        Class<?> loaded = null;
        if (driverClass != null) {
            try {
                loaded = Class.forName(driverClass);
            } catch (ClassNotFoundException e) {
                throw new SQLException("JDBC driver not on the webapp classpath: " + driverClass, e);
            }
        }

        try {
            return DriverManager.getConnection(url, config.getUsername(), config.getPassword());
        } catch (SQLException primary) {
            // Fallback: DriverManager also filters drivers by caller classloader,
            // which can still reject a WEB-INF/lib driver. Use the Driver directly.
            if (loaded == null) {
                throw primary;
            }
            try {
                Driver driver = (Driver) loaded.getDeclaredConstructor().newInstance();
                Properties props = new Properties();
                if (config.getUsername() != null) {
                    props.setProperty("user", config.getUsername());
                }
                props.setProperty("password", config.getPassword() == null ? "" : config.getPassword());
                Connection connection = driver.connect(url, props);
                if (connection == null) {
                    throw primary;
                }
                return connection;
            } catch (SQLException e) {
                throw e;
            } catch (Exception e) {
                throw new SQLException("Direct driver connect failed for " + driverClass, e);
            }
        }
    }
}
