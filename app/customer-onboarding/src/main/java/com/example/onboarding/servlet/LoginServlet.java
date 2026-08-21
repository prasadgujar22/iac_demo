package com.example.onboarding.servlet;

import javax.servlet.ServletException;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import javax.servlet.http.HttpSession;
import java.io.IOException;

@WebServlet("/login")
public class LoginServlet extends BaseServlet {
    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {
        if (isLoggedIn(request)) {
            response.sendRedirect(request.getContextPath() + "/dashboard");
            return;
        }
        request.getRequestDispatcher("/login.jsp").forward(request, response);
    }

    @Override
    protected void doPost(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {
        String username = request.getParameter("username");
        String password = request.getParameter("password");

        String configuredUsername = getServletContext().getInitParameter("appUsername");
        String configuredPassword = getServletContext().getInitParameter("appPassword");

        if (configuredUsername.equals(username) && configuredPassword.equals(password)) {
            HttpSession session = request.getSession(true);
            session.setAttribute("authenticated", true);
            session.setAttribute("username", username);
            response.sendRedirect(request.getContextPath() + "/dashboard");
            return;
        }

        request.setAttribute("errorMessage", "Invalid username or password.");
        request.getRequestDispatcher("/login.jsp").forward(request, response);
    }
}
