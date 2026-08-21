# Customer Onboarding WAR for Oracle WebLogic 14.1.2

This repository contains a Maven-based Java web application packaged as a `.war` file for deployment to Oracle WebLogic Server 14.1.2.

## Features

- Login page with session-based authentication
- Customer onboarding tab with a submission form
- Reports tab listing onboarded customers
- Oracle Database Express Edition integration using Oracle JDBC
- WebLogic deployment descriptors included

## Default Application Credentials

- Username: `admin`
- Password: `welcome1`

## Oracle XE Setup

Run the SQL script in `database/setup.sql` against your Oracle XE instance:

```sql
@database/setup.sql
```

By default the application expects Oracle XE at:

```text
jdbc:oracle:thin:@//localhost:1521/XEPDB1
```

Update these context params in `src/main/webapp/WEB-INF/web.xml` for your environment:

- `dbUrl`
- `dbUser`
- `dbPassword`
- `appUsername`
- `appPassword`

## Build the WAR

```bash
mvn clean package
```

Generated artifact:

```text
target/customer-onboarding.war
```

## Deploy to Oracle WebLogic 14.1.2

1. Log in to the WebLogic Administration Console.
2. Go to **Deployments** -> **Install**.
3. Upload or select `target/customer-onboarding.war`.
4. Accept the default context root `/customer-onboarding` or update it in `weblogic.xml`.
5. Start the deployment.

After deployment, access the application at:

```text
http://<host>:<port>/customer-onboarding
```
# java_session_management_demo
