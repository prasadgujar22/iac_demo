<%@ page contentType="text/html; charset=UTF-8" pageEncoding="UTF-8" %>
<%@ page import="java.util.List" %>
<%@ page import="com.example.onboarding.model.Customer" %>
<%!
    // Escapes for safe placement inside an HTML attribute or text node, and
    // turns null into "" so pre-filling the edit form never prints "null".
    // Existing records may legitimately contain characters like & or " (e.g.
    // "Smith & Sons", addresses with quotes) that would otherwise break the
    // attribute or, worse, let stored data inject markup.
    private String nullToEmpty(String value) {
        if (value == null) {
            return "";
        }
        return value.replace("&", "&amp;")
                     .replace("\"", "&quot;")
                     .replace("<", "&lt;")
                     .replace(">", "&gt;");
    }
%>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Customer Onboarding Dashboard</title>
    <link rel="stylesheet" href="${pageContext.request.contextPath}/css/styles.css">
</head>
<body>
<%
    String activeTab = (String) request.getAttribute("activeTab");
    if (activeTab == null) {
        activeTab = "onboarding";
    }
    String flashMessage = (String) session.getAttribute("flashMessage");
    String flashError = (String) session.getAttribute("flashError");
    session.removeAttribute("flashMessage");
    session.removeAttribute("flashError");
    String databaseError = (String) request.getAttribute("databaseError");
    List<Customer> customers = (List<Customer>) request.getAttribute("customers");
    Customer editCustomer = (Customer) request.getAttribute("editCustomer");
    boolean isEditMode = editCustomer != null;
%>

<div class="page-shell">
    <header class="page-header">
        <div>
            <h1>Customer Onboarding Portal</h1>
            <p>Manage customer submissions and review onboarded customers.</p>
        </div>
        <div class="header-actions">
            <span class="welcome-text">Signed in as <strong><%= session.getAttribute("username") %></strong></span>
            <a href="${pageContext.request.contextPath}/logout" class="secondary-btn">Logout</a>
        </div>
    </header>

    <% if (flashMessage != null) { %>
    <div class="alert success"><%= flashMessage %></div>
    <% } %>
    <% if (flashError != null) { %>
    <div class="alert error"><%= flashError %></div>
    <% } %>
    <% if (databaseError != null) { %>
    <div class="alert error">Database connection issue: <%= databaseError %></div>
    <% } %>

    <nav class="tabs">
        <a class="tab <%= "onboarding".equals(activeTab) ? "active" : "" %>"
           href="${pageContext.request.contextPath}/dashboard?tab=onboarding">Customer Onboarding</a>
        <a class="tab <%= "reports".equals(activeTab) ? "active" : "" %>"
           href="${pageContext.request.contextPath}/dashboard?tab=reports">Reports</a>
    </nav>

    <main class="tab-content">
        <% if ("reports".equals(activeTab)) { %>
        <section class="card">
            <h2>Onboarded Customers</h2>
            <table class="report-table">
                <thead>
                <tr>
                    <th>ID</th>
                    <th>Customer Name</th>
                    <th>Company</th>
                    <th>Email</th>
                    <th>Phone</th>
                    <th>Status</th>
                    <th>Created Date</th>
                    <th>Actions</th>
                </tr>
                </thead>
                <tbody>
                <% if (customers == null || customers.isEmpty()) { %>
                <tr>
                    <td colspan="8" class="empty-state">No customers have been onboarded yet.</td>
                </tr>
                <% } else { %>
                <% for (Customer customer : customers) { %>
                <tr>
                    <td><%= customer.getId() %></td>
                    <td><%= customer.getCustomerName() %></td>
                    <td><%= customer.getCompanyName() %></td>
                    <td><%= customer.getEmail() %></td>
                    <td><%= customer.getPhoneNumber() == null ? "" : customer.getPhoneNumber() %></td>
                    <td><%= customer.getOnboardingStatus() %></td>
                    <td><%= customer.getCreatedDate() %></td>
                    <td>
                        <a class="secondary-btn small-btn"
                           href="${pageContext.request.contextPath}/dashboard?tab=onboarding&editId=<%= customer.getId() %>">Edit</a>
                    </td>
                </tr>
                <% } %>
                <% } %>
                </tbody>
            </table>
        </section>
        <% } else { %>
        <section class="card">
            <h2><%= isEditMode ? "Edit Customer #" + editCustomer.getId() : "New Customer Onboarding" %></h2>
            <form action="${pageContext.request.contextPath}/customers" method="post" class="form-grid two-column">
                <% if (isEditMode) { %>
                <input type="hidden" name="id" value="<%= editCustomer.getId() %>">
                <% } %>
                <div>
                    <label for="customerName">Customer Name</label>
                    <input id="customerName" name="customerName" type="text" required
                           value="<%= isEditMode ? nullToEmpty(editCustomer.getCustomerName()) : "" %>">
                </div>
                <div>
                    <label for="companyName">Company Name</label>
                    <input id="companyName" name="companyName" type="text" required
                           value="<%= isEditMode ? nullToEmpty(editCustomer.getCompanyName()) : "" %>">
                </div>
                <div>
                    <label for="email">Email</label>
                    <input id="email" name="email" type="email" required
                           value="<%= isEditMode ? nullToEmpty(editCustomer.getEmail()) : "" %>">
                </div>
                <div>
                    <label for="phoneNumber">Phone Number</label>
                    <input id="phoneNumber" name="phoneNumber" type="text"
                           value="<%= isEditMode ? nullToEmpty(editCustomer.getPhoneNumber()) : "" %>">
                </div>
                <div>
                    <label for="addressLine1">Address Line 1</label>
                    <input id="addressLine1" name="addressLine1" type="text"
                           value="<%= isEditMode ? nullToEmpty(editCustomer.getAddressLine1()) : "" %>">
                </div>
                <div>
                    <label for="addressLine2">Address Line 2</label>
                    <input id="addressLine2" name="addressLine2" type="text"
                           value="<%= isEditMode ? nullToEmpty(editCustomer.getAddressLine2()) : "" %>">
                </div>
                <div>
                    <label for="city">City</label>
                    <input id="city" name="city" type="text"
                           value="<%= isEditMode ? nullToEmpty(editCustomer.getCity()) : "" %>">
                </div>
                <div>
                    <label for="state">State</label>
                    <input id="state" name="state" type="text"
                           value="<%= isEditMode ? nullToEmpty(editCustomer.getState()) : "" %>">
                </div>
                <div>
                    <label for="postalCode">Postal Code</label>
                    <input id="postalCode" name="postalCode" type="text"
                           value="<%= isEditMode ? nullToEmpty(editCustomer.getPostalCode()) : "" %>">
                </div>
                <div>
                    <label for="country">Country</label>
                    <input id="country" name="country" type="text"
                           value="<%= isEditMode ? nullToEmpty(editCustomer.getCountry()) : "" %>">
                </div>
                <div>
                    <label for="onboardingStatus">Onboarding Status</label>
                    <%
                        String currentStatus = isEditMode ? nullToEmpty(editCustomer.getOnboardingStatus()) : "";
                    %>
                    <select id="onboardingStatus" name="onboardingStatus" required>
                        <option value="" <%= currentStatus.isEmpty() ? "selected" : "" %>>Select status</option>
                        <option value="New" <%= "New".equals(currentStatus) ? "selected" : "" %>>New</option>
                        <option value="In Review" <%= "In Review".equals(currentStatus) ? "selected" : "" %>>In Review</option>
                        <option value="Approved" <%= "Approved".equals(currentStatus) ? "selected" : "" %>>Approved</option>
                        <option value="Completed" <%= "Completed".equals(currentStatus) ? "selected" : "" %>>Completed</option>
                    </select>
                </div>
                <div class="full-width">
                    <label for="notes">Notes</label>
                    <textarea id="notes" name="notes" rows="4"><%= isEditMode ? nullToEmpty(editCustomer.getNotes()) : "" %></textarea>
                </div>
                <div class="full-width">
                    <button type="submit" class="primary-btn"><%= isEditMode ? "Save Changes" : "Submit Customer Details" %></button>
                    <% if (isEditMode) { %>
                    <a href="${pageContext.request.contextPath}/dashboard?tab=onboarding" class="secondary-btn">Cancel</a>
                    <% } %>
                </div>
            </form>
        </section>
        <% } %>
    </main>
</div>
</body>
</html>
