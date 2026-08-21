package com.example.onboarding.servlet;

import com.example.onboarding.dao.CustomerDao;
import com.example.onboarding.model.Customer;
import com.example.onboarding.util.DatabaseConfig;

import javax.servlet.ServletException;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.sql.SQLException;

@WebServlet("/dashboard")
public class DashboardServlet extends BaseServlet {
    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {
        if (!isLoggedIn(request)) {
            response.sendRedirect(request.getContextPath() + "/login");
            return;
        }

        DatabaseConfig config = DatabaseConfig.from(getServletContext());
        CustomerDao customerDao = new CustomerDao(config);

        String activeTab = request.getParameter("tab");
        if (activeTab == null || activeTab.isBlank()) {
            activeTab = "onboarding";
        }

        try {
            customerDao.initializeSchema();
            request.setAttribute("customers", customerDao.findAll());

            // ?tab=onboarding&editId=N loads that record into the form so it
            // doubles as both the "new customer" and "edit customer" screen.
            String editIdParam = request.getParameter("editId");
            if ("onboarding".equals(activeTab) && editIdParam != null && !editIdParam.isBlank()) {
                try {
                    long editId = Long.parseLong(editIdParam.trim());
                    Customer editCustomer = customerDao.findById(editId);
                    if (editCustomer == null) {
                        request.getSession().setAttribute("flashError", "Customer #" + editId + " was not found.");
                    } else {
                        request.setAttribute("editCustomer", editCustomer);
                    }
                } catch (NumberFormatException exception) {
                    request.getSession().setAttribute("flashError", "Invalid customer id.");
                }
            }
        } catch (SQLException exception) {
            request.setAttribute("databaseError", exception.getMessage());
        }

        request.setAttribute("activeTab", activeTab);
        request.getRequestDispatcher("/dashboard.jsp").forward(request, response);
    }
}
