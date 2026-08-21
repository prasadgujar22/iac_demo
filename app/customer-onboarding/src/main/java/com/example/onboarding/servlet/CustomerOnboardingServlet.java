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
import java.time.LocalDate;

@WebServlet("/customers")
public class CustomerOnboardingServlet extends BaseServlet {
    @Override
    protected void doPost(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {
        if (!isLoggedIn(request)) {
            response.sendRedirect(request.getContextPath() + "/login");
            return;
        }

        // Presence of a non-blank "id" field distinguishes an edit (the edit
        // form carries a hidden id input) from a new submission, which has none.
        String idParam = trim(request.getParameter("id"));
        boolean isEdit = !isBlank(idParam);

        Customer customer = new Customer();
        customer.setCustomerName(trim(request.getParameter("customerName")));
        customer.setCompanyName(trim(request.getParameter("companyName")));
        customer.setEmail(trim(request.getParameter("email")));
        customer.setPhoneNumber(trim(request.getParameter("phoneNumber")));
        customer.setAddressLine1(trim(request.getParameter("addressLine1")));
        customer.setAddressLine2(trim(request.getParameter("addressLine2")));
        customer.setCity(trim(request.getParameter("city")));
        customer.setState(trim(request.getParameter("state")));
        customer.setPostalCode(trim(request.getParameter("postalCode")));
        customer.setCountry(trim(request.getParameter("country")));
        customer.setOnboardingStatus(trim(request.getParameter("onboardingStatus")));
        customer.setNotes(trim(request.getParameter("notes")));
        customer.setCreatedDate(LocalDate.now());

        String backToTab = isEdit ? "onboarding&editId=" + idParam : "onboarding";

        if (isBlank(customer.getCustomerName())
                || isBlank(customer.getCompanyName())
                || isBlank(customer.getEmail())
                || isBlank(customer.getOnboardingStatus())) {
            request.getSession().setAttribute("flashError",
                    "Customer name, company name, email, and onboarding status are required.");
            response.sendRedirect(request.getContextPath() + "/dashboard?tab=" + backToTab);
            return;
        }

        DatabaseConfig config = DatabaseConfig.from(getServletContext());
        CustomerDao customerDao = new CustomerDao(config);

        try {
            customerDao.initializeSchema();
            if (isEdit) {
                long id;
                try {
                    id = Long.parseLong(idParam);
                } catch (NumberFormatException exception) {
                    request.getSession().setAttribute("flashError", "Invalid customer id.");
                    response.sendRedirect(request.getContextPath() + "/dashboard?tab=reports");
                    return;
                }
                customer.setId(id);
                boolean updated = customerDao.update(customer);
                if (updated) {
                    request.getSession().setAttribute("flashMessage", "Customer details updated successfully.");
                } else {
                    request.getSession().setAttribute("flashError",
                            "Customer #" + id + " no longer exists; it may have been removed.");
                }
            } else {
                customerDao.save(customer);
                request.getSession().setAttribute("flashMessage", "Customer details submitted successfully.");
            }
        } catch (SQLException exception) {
            String verb = isEdit ? "update" : "save";
            request.getSession().setAttribute("flashError", "Unable to " + verb + " customer: " + exception.getMessage());
        }

        response.sendRedirect(request.getContextPath() + "/dashboard?tab=reports");
    }

    private String trim(String value) {
        return value == null ? null : value.trim();
    }

    private boolean isBlank(String value) {
        return value == null || value.isBlank();
    }
}
