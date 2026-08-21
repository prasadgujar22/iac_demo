<%@ page contentType="text/html; charset=UTF-8" pageEncoding="UTF-8" %>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Customer Onboarding Login</title>
    <link rel="stylesheet" href="${pageContext.request.contextPath}/css/styles.css">
</head>
<body class="login-body">
<div class="login-card">
    <h1>Customer Onboarding</h1>
    <p class="subtitle">Sign in to onboard customers and view reports.</p>

    <% String errorMessage = (String) request.getAttribute("errorMessage"); %>
    <% if (errorMessage != null) { %>
    <div class="alert error"><%= errorMessage %></div>
    <% } %>

    <form action="${pageContext.request.contextPath}/login" method="post" class="form-grid">
        <label for="username">Username</label>
        <input id="username" name="username" type="text" required>

        <label for="password">Password</label>
        <input id="password" name="password" type="password" required>

        <button type="submit" class="primary-btn">Login</button>
    </form>

    <div class="login-hint">
        Default login: <strong>admin</strong> / <strong>welcome1</strong>
    </div>
</div>
</body>
</html>
