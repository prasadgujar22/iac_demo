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

    public static DatabaseConfig from(ServletContext servletContext) {
        return new DatabaseConfig(
                servletContext.getInitParameter("dbUrl"),
                servletContext.getInitParameter("dbUser"),
                servletContext.getInitParameter("dbPassword")
        );
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
