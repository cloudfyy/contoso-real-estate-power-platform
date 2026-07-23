# Payments SQL Initialization Troubleshooting

This document captures the troubleshooting path for initializing the Payments API SQL database in locked-down Azure environments where SQL public network access is disabled and SQL authentication is not allowed.

## Expected Flow

The database is initialized through the Payments API Function App because the Function App is integrated with the private network that can reach Azure SQL.

The initialization script performs these steps:

1. Reads the `azd` environment values from `.azure/<environment>/.env`.
1. Grants the Payments API initialization app role to the current user and the API client service principal.
1. Adds the current user and Function App managed identity to a temporary SQL Entra administrator group.
1. Sets that group as the SQL Entra administrator.
1. Temporarily sets `SQL_INITIALIZATION_ENABLED=true` and `SQL_MANAGED_IDENTITY_OBJECT_ID=<function-principal-id>` on the Function App.
1. Restarts the Function App and waits for `GET /api/ping/function-ready`.
1. Calls `POST /api/database/initialize-sql` with a client credentials token for the Payments API app registration.
1. Disables the initialization endpoint and removes the Function App identity from the temporary SQL admin group.

After a successful run, `SQL_INITIALIZATION_ENABLED` should be `false` and the Function App identity should keep only database-level permissions.

## Useful Telemetry Queries

Use Application Insights Logs for the Payments API resource.

Check whether the initialization endpoint is being recorded as a Function request:

```kusto
requests
| where timestamp > ago(1h)
| where url has "initialize-sql" or name has "initializePaymentsDatabase"
| project timestamp, name, url, success, resultCode, duration, operation_Id, customDimensions
| order by timestamp desc
```

Check startup route mapping and route conflicts:

```kusto
traces
| where timestamp > ago(1h)
| where message has "Initializing function HTTP routes"
   or message has "initializePaymentsDatabase"
   or message has "specified route conflicts"
| project timestamp, severityLevel, message, customDimensions
| order by timestamp desc
```

Check initialization failures:

```kusto
exceptions
| where timestamp > ago(1h)
| where operation_Name has "initializePaymentsDatabase"
   or innermostMessage has "initializePaymentsDatabase"
   or outerMessage has "initializePaymentsDatabase"
| project timestamp, type, outerMessage, innermostMessage, operation_Name, operation_Id, customDimensions
| order by timestamp desc
```

## Issue: 404 from `/api/admin/initialize-sql`

Symptoms:

- The script repeatedly prints `status 404`.
- `requests | where url has "initialize-sql"` returns no matching Function request telemetry.
- Ping requests are visible in Application Insights.
- Function host startup traces show the Function App loaded fewer functions than expected.
- Startup traces contain an error like:

```text
The 'initializePaymentsDatabase' function is in error: The specified route conflicts with one or more built in routes.
```

Cause:

Azure Functions reserves built-in routes under the `admin` prefix. An HTTP trigger route such as `admin/initialize-sql` conflicts with those built-in routes, so the host does not map the custom function route.

Fix:

Use a non-reserved route. The Payments API uses:

```text
POST /api/database/initialize-sql
```

After redeployment, startup traces should show:

```text
Mapped function route 'api/database/initialize-sql' [post] to 'initializePaymentsDatabase'
```

## Issue: 401 Unauthorized After the Route Is Mapped

Symptoms:

- The endpoint no longer returns 404.
- The script fails with `401 Unauthorized`.
- Application Insights shows `initializePaymentsDatabase unauthorized access attempt`.
- The error says the required role is `CanInitializePaymentsDatabase`, but current roles are empty.

Cause:

The Function App uses App Service Authentication, also known as EasyAuth, with `AllowAnonymous`. The Functions are declared with `AuthorizationLevel.Anonymous`, and authorization is enforced in code by reading role claims. In .NET isolated with ASP.NET Core integration, `HttpContext.User` may not contain the EasyAuth role claims even when EasyAuth validated the bearer token.

Fix:

When `HttpContext.User` does not contain `roles`, parse the EasyAuth-provided `X-MS-CLIENT-PRINCIPAL` header and use those claims for the existing role check.

## Issue: 500 During `CREATE USER ... FROM EXTERNAL PROVIDER`

Symptoms:

- The route and authorization work.
- The endpoint returns `500 Internal Server Error`.
- Application Insights contains SQL errors like:

```text
Principal '<function-app-name>' could not be resolved.
Server identity is not configured. Please follow the steps in "Assign an Azure AD identity to your server and add Directory Reader permission to your identity".
Cannot add the principal '<function-app-name>', because it does not exist or you do not have permission.
```

Cause:

`CREATE USER [name] FROM EXTERNAL PROVIDER` requires Azure SQL to resolve the Entra principal through Microsoft Graph. That requires SQL server identity and directory permissions that may not be available in governed environments.

Fix:

Create the database user with the managed identity object id instead of asking SQL to resolve the display name:

```sql
CREATE USER [<function-app-name>] WITH SID = 0x<object-id-guid-bytes>, TYPE = E;
```

The script sets `SQL_MANAGED_IDENTITY_OBJECT_ID` from the Function App system-assigned identity principal id. The API converts that object id to the SID format expected by SQL Server.

## Issue: 403 or Host Lock Failures from Storage

Symptoms:

- Function startup fails or intermittently returns `503`.
- Application Insights or Kudu logs contain `AzureWebJobsStorage`, `AuthorizationFailure`, or host lock errors.

Cause:

The Function runtime depends on the storage account for host coordination. When storage public network access and shared key access are disabled, the Function App needs managed identity storage settings and private endpoints for the required storage services.

Fix:

Use a `StorageV2` account, configure managed identity storage settings, and create private endpoints/private DNS for blob, queue, table, and file services.

## Issue: Function Startup Fails When Key Vault Public Access Is Disabled

Symptoms:

- Function startup fails before requests reach user code.
- Logs show Key Vault access failures.

Cause:

The application reads configuration from Key Vault at startup. If Key Vault public network access is disabled, the Function App must reach Key Vault through private networking.

Fix:

Create a Key Vault private endpoint and link the private DNS zone to the application virtual network.

## Validation Checklist

After applying fixes, validate these items:

1. `azd deploy payments-api --environment <environment>` succeeds.
1. App Insights startup traces show `11 functions loaded`.
1. Startup traces map `api/database/initialize-sql` to `initializePaymentsDatabase`.
1. `./infra/scripts/initialize-sql-via-function.ps1 -azureEnv <environment>` returns `Payments database initialized.`
1. `SQL_INITIALIZATION_ENABLED` is reset to `false` after the script completes.
1. No new `AzureWebJobsStorage`, `AuthorizationFailure`, route conflict, or SQL principal resolution errors appear in recent Application Insights logs.