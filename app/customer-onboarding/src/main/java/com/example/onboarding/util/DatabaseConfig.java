package com.example.onboarding.util;

import javax.servlet.ServletContext;

public class DatabaseConfig {
    private final String url;
    private final String username;
    private final String password;

    public DatabaseConfig(String url, String username, String password) {
        this.url = url;
        this.username = username;
        this.password = password;
    }

    /**
     * Resolve the JDBC settings, preferring the environment over what was
     * built into the WAR.
     *
     * <p>Order is environment variable, then system property, then the
     * {@code web.xml} context parameter. The last of those is templated at
     * BUILD time, so anything environment-specific baked there — above all the
     * database host — is frozen into the domain image the WAR ships in. When
     * that host changes, an image built earlier keeps dialling the old address
     * and fails at runtime with {@code ORA-17820: The network adapter could
     * not establish the connection}.
     *
     * <p>Reading the environment first lets the deployment supply the current
     * address instead: the operator injects {@code DB_URL} into every server
     * pod from {@code spec.serverPod.env} (see terraform/20-wls-k8s), so the
     * same image works wherever the database happens to live. The context
     * parameters remain as the fallback, which is what keeps {@code DB_MODE=h2}
     * and plain non-container runs of this application working unchanged.
     */
    public static DatabaseConfig from(ServletContext servletContext) {
        return new DatabaseConfig(
                resolve("DB_URL", "db.url", servletContext, "dbUrl"),
                resolve("DB_USER", "db.user", servletContext, "dbUser"),
                resolve("DB_PASSWORD", "db.password", servletContext, "dbPassword")
        );
    }

    private static String resolve(String envName,
                                  String propertyName,
                                  ServletContext servletContext,
                                  String initParamName) {
        String value = System.getenv(envName);
        if (isBlank(value)) {
            value = System.getProperty(propertyName);
        }
        if (isBlank(value)) {
            value = servletContext.getInitParameter(initParamName);
        }
        return value;
    }

    // An empty env var is treated as "not set": a container runtime that
    // defines the variable with no value must not blank out a working
    // context-param fallback.
    private static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }

    public String getUrl() {
        return url;
    }

    public String getUsername() {
        return username;
    }

    public String getPassword() {
        return password;
    }
}
