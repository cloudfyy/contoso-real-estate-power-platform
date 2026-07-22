// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Core;
using Azure.Identity;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.WebJobs.Extensions.OpenApi.Core.Attributes;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.OData.Edm;
using Microsoft.OData.ModelBuilder;
using Microsoft.OData.UriParser;
using Microsoft.OpenApi.Models;
using SqlKata;
using SqlKata.Execution;
using Stripe;
using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;

namespace Contoso.API.Payments;

enum PaymentAppRoles
{
    CanQueryPayments,
    CanAddPayments,
    CanInitializePaymentsDatabase
}
public class PaymentFunction
{
    private readonly ILogger<PaymentFunction> _logger;
    private readonly IConfiguration _configuration;

    public PaymentFunction(IConfiguration configuration, ILogger<PaymentFunction> log)
    {
        _logger = log;
        _configuration = configuration;
    }


    [Function("listPayments")]
    [OpenApiOperation(operationId: "listPayments", tags: new[] { "payment" }, Summary = "Get payments", Description = "Returns a JSON array of Payments")]
    [OpenApiParameter(name: "$filter", In = ParameterLocation.Query, Required = false, Type = typeof(string), Description = "Filter the results")]
    [OpenApiParameter(name: "$orderby", In = ParameterLocation.Query, Required = false, Type = typeof(string), Description = "Order the results")]
    [OpenApiParameter(name: "$top", In = ParameterLocation.Query, Required = false, Type = typeof(int), Description = "Limit the number of results")]
    [OpenApiParameter(name: "$skip", In = ParameterLocation.Query, Required = false, Type = typeof(int), Description = "Skip a number of results")]

    [OpenApiResponseWithBody(statusCode: HttpStatusCode.OK, contentType: "application/json", bodyType: typeof(List<Payment>), Description = "OK - Returns array of Payments")]
    public async Task<IActionResult> ListPayments(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "payments")] HttpRequest req)
    {
        this._logger.LogInformation("listPayments function start");
       
        try
        {
            // Role Check
            req.HttpContext.User.AssertUserInRoles(PaymentAppRoles.CanQueryPayments.ToString());

            var modelBuilder = new ODataConventionModelBuilder();
            modelBuilder.EntitySet<Payment>("Payments");
            IEdmModel model = modelBuilder.GetEdmModel();

            // Get root path from req
            Uri serviceRoot = new($"{req.Scheme}://{req.Host}");

            Uri requestUri = new($"Payments{req.QueryString}", UriKind.Relative);
            ODataUriParser parser = new(model, serviceRoot, requestUri);
            FilterClause filter = parser.ParseFilter();
            OrderByClause orderby = parser.ParseOrderBy();
            long? top = parser.ParseTop();
            long? skip = parser.ParseSkip();

            var payments = await ListPaymentsInternal(filter, orderby, top, skip);

            this._logger.LogInformation("listPayments function: opened connection");

            return new OkObjectResult(payments);
        }
        catch (UnauthorizedAccessException ex)
        {
            this._logger.LogWarning(ex, $"listPayments Unauthorized access attempt. {ex.Message}");
            return new UnauthorizedResult();
        }
        catch (Exception ex)
        {
            this._logger.LogError(ex, "listPayments function: error occurred");
            return new StatusCodeResult((int)HttpStatusCode.InternalServerError);
        }
    }

    [Function("findPaymentById")]
    [OpenApiOperation(operationId: "findPaymentById", tags: new[] { "payment" }, Summary = "Get payment by id", Description = "Return Payment record matching {id}")]
    [OpenApiParameter(name: "id", In = ParameterLocation.Path, Required = true, Type = typeof(string), Description = "The ID of the payment")]
    [OpenApiResponseWithBody(statusCode: HttpStatusCode.OK, contentType: "application/json", bodyType: typeof(Payment), Description = "OK - Returns Payment object")]
    public async Task<IActionResult> FindPaymentById(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "payments/{id}")] HttpRequest req,
     string id)
    {
        try
        {
            // Role Check
            req.HttpContext.User.AssertUserInRoles(PaymentAppRoles.CanQueryPayments.ToString());

            await using SqlConnection sqlConnection = await Connect();
            var db = new QueryFactory(sqlConnection, new SqlKata.Compilers.SqlServerCompiler());

            var query = new Query("dbo.payment")
                .Select("id", "userId", "reservationId", "provider", "status", "amount", "currency", "createdAt")
                .Where("id", id);

            var payment = await db.FirstOrDefaultAsync<Payment>(query);

            // Set the timezone of payment.createdAt to UTC if it's not null
            if (payment != null)
            {
                payment.CreatedAt = DateTime.SpecifyKind(payment.CreatedAt, DateTimeKind.Utc);
            }

            if (payment == null)
            {
                return new NotFoundResult();
            }

            this._logger.LogInformation("findPaymentById function: found payment");

            return new OkObjectResult(payment);
        }
        catch (UnauthorizedAccessException ex)
        {
            this._logger.LogWarning(ex, $"findPaymentById unauthorized access attempt. {ex.Message}");
            return new UnauthorizedResult();
        }
        catch (Exception ex)
        {
            this._logger.LogError(ex, "FindPaymentById function:" + ex.ToString());
            return new StatusCodeResult((int)HttpStatusCode.InternalServerError);
        }
    }

    [Function("addPayment")]
    [OpenApiOperation(operationId: "addPayment", tags: new[] { "payment" }, Summary = "Add a payment", Description = "Adds a payment to the database")]
    [OpenApiRequestBody(contentType: "application/json", bodyType: typeof(Payment), Required = true, Description = "Payment object to be added")]
    [OpenApiResponseWithBody(statusCode: HttpStatusCode.OK, contentType: "application/json", bodyType: typeof(Payment), Description = "OK - Returns Payment object")]

    public async Task<IActionResult> AddPayment(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "payments")] HttpRequest req)
    {
        this._logger.LogInformation("addPayment function start");

        try
        {
            // Role Check
            req.HttpContext.User.AssertUserInRoles(PaymentAppRoles.CanAddPayments.ToString());

            var requestBody = await new StreamReader(req.Body).ReadToEndAsync();
            var payment = JsonConvert.DeserializeObject<Payment>(requestBody);
            if (payment == null)
            {
                return new BadRequestObjectResult(new { error = "Invalid request body" });
            }

            await AddPaymentInternal(payment);
            this._logger.LogInformation("addPayment function: inserted payment");
            return new OkObjectResult(payment);
        }
        catch (UnauthorizedAccessException ex)
        {
            this._logger.LogWarning(ex, $"addPayment unauthorized access attempt. {ex.Message}");
            return new UnauthorizedResult();
        }
        catch (Exception ex)
        {
            this._logger.LogError(ex, "addPayment function:" + ex.ToString());
            return new StatusCodeResult((int)HttpStatusCode.InternalServerError);
        }
    }

    [Function("initializePaymentsDatabase")]
    [OpenApiOperation(operationId: "initializePaymentsDatabase", tags: new[] { "admin" }, Summary = "Initialize payments database", Description = "Initializes the payments database for Entra ID-only SQL deployments")]
    [OpenApiResponseWithoutBody(statusCode: HttpStatusCode.OK, Description = "OK - Database initialized")]
    [OpenApiResponseWithoutBody(statusCode: HttpStatusCode.NotFound, Description = "Initialization endpoint is disabled")]
    [OpenApiResponseWithoutBody(statusCode: HttpStatusCode.Unauthorized, Description = "Unauthorized")]
    public async Task<IActionResult> InitializePaymentsDatabase(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "admin/initialize-sql")] HttpRequest req)
    {
        try
        {
            if (!bool.TryParse(_configuration["SQL_INITIALIZATION_ENABLED"], out bool initializationEnabled) || !initializationEnabled)
            {
                return new NotFoundResult();
            }

            req.HttpContext.User.AssertUserInRoles(PaymentAppRoles.CanInitializePaymentsDatabase.ToString());

            var managedIdentityName = _configuration["SQL_MANAGED_IDENTITY_USER_NAME"];
            if (string.IsNullOrWhiteSpace(managedIdentityName))
            {
                managedIdentityName = _configuration["WEBSITE_SITE_NAME"];
            }

            if (string.IsNullOrWhiteSpace(managedIdentityName))
            {
                throw new InvalidOperationException("SQL managed identity user name was not configured.");
            }

            await InitializePaymentsDatabaseInternal(managedIdentityName);
            return new OkObjectResult(new { message = "Payments database initialized." });
        }
        catch (UnauthorizedAccessException ex)
        {
            this._logger.LogWarning(ex, $"initializePaymentsDatabase unauthorized access attempt. {ex.Message}");
            return new UnauthorizedResult();
        }
        catch (Exception ex)
        {
            this._logger.LogError(ex, "initializePaymentsDatabase function: error occurred");
            return new StatusCodeResult((int)HttpStatusCode.InternalServerError);
        }
    }

    internal async Task<IEnumerable<Payment>> ListPaymentsInternal(FilterClause filter, OrderByClause orderby, long? top, long? skip)
    {
        var query = new Query("dbo.payment")
            .Select("id", "userId", "reservationId", "provider", "status", "amount", "currency", "createdAt");

        if (filter != null)
        {
            query = ApplyFilter(query, filter.Expression);
        }

        if (orderby != null)
        {

            var node = orderby.Expression as SingleValuePropertyAccessNode ?? throw new InvalidOperationException("The order by clause is invalid");
            if (orderby.Direction == OrderByDirection.Ascending)
            {
                query = query.OrderBy(node.Property.Name);
            }
            else
            {
                query = query.OrderByDesc(node.Property.Name);
            }

        }

        if (top.HasValue)
        {
            query = query.Limit((int)top.Value);
        }

        if (skip.HasValue)
        {
            query = query.Offset((int)skip.Value);
        }


        var compiler = new SqlKata.Compilers.SqlServerCompiler();
        var compiled = compiler.Compile(query);
        var serializedBindings = string.Join(", ", compiled.NamedBindings.Select(kv => $"{kv.Key}={kv.Value}"));

        this._logger.LogInformation($"listPayments function: {compiled.Sql} {serializedBindings}");

        await using SqlConnection sqlConnection = await Connect();
        var db = new QueryFactory(sqlConnection, compiler);

        return await db.GetAsync<Payment>(query);
    }

    private static Query ApplyFilter(Query query, SingleValueNode expression)
    {
        if (expression is BinaryOperatorNode binaryOperatorNode)
        {
            if (binaryOperatorNode.Left is SingleValuePropertyAccessNode left && binaryOperatorNode.Right is ConstantNode right)
            {
                var propertyName = left.Property.Name;
                var value = right.Value;

                query = binaryOperatorNode.OperatorKind switch
                {
                    BinaryOperatorKind.Equal => query.Where(propertyName, "=", value),
                    BinaryOperatorKind.NotEqual => query.Where(propertyName, "<>", value),
                    BinaryOperatorKind.GreaterThan => query.Where(propertyName, ">", value),
                    BinaryOperatorKind.GreaterThanOrEqual => query.Where(propertyName, ">=", value),
                    BinaryOperatorKind.LessThan => query.Where(propertyName, "<", value),
                    BinaryOperatorKind.LessThanOrEqual => query.Where(propertyName, "<=", value),
                    _ => throw new Exception("Unsupported operator: " + binaryOperatorNode.OperatorKind),
                };
            }
            else if (binaryOperatorNode.Left is BinaryOperatorNode || binaryOperatorNode.Right is BinaryOperatorNode)
            {
                var leftQuery = ApplyFilter(new Query(), binaryOperatorNode.Left);
                var rightQuery = ApplyFilter(new Query(), binaryOperatorNode.Right);

                switch (binaryOperatorNode.OperatorKind)
                {
                    case BinaryOperatorKind.And:
                        query = query.Where(q => leftQuery).Where(q => rightQuery);
                        break;
                    case BinaryOperatorKind.Or:
                        query = query.Where(q => leftQuery).OrWhere(q => rightQuery);
                        break;
                }
            }
        }

        return query;
    }


    

    internal async Task<int> AddPaymentInternal(Payment payment)
    {
        await using SqlConnection sqlConnection = await Connect();
        var db = new QueryFactory(sqlConnection, new SqlKata.Compilers.SqlServerCompiler());

        var id = db.Query("dbo.payment").InsertGetId<int>(new
        {
            userId = payment.UserId,
            reservationId = payment.ReservationId,
            provider = payment.Provider,
            status = payment.Status,
            amount = payment.Amount,
            currency = payment.Currency,
            createdAt = payment.CreatedAt
        });

        payment.Id = id;

        return payment.Id;
    }

    internal async Task InitializePaymentsDatabaseInternal(string managedIdentityName)
    {
        await using SqlConnection sqlConnection = await Connect();
        await using SqlCommand command = sqlConnection.CreateCommand();
        var managedIdentityLiteral = EscapeSqlLiteral(managedIdentityName);
        var managedIdentityIdentifier = QuoteSqlIdentifier(managedIdentityName);
        command.CommandText = $@"
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = N'{managedIdentityLiteral}')
BEGIN
    EXEC(N'CREATE USER {managedIdentityIdentifier} FROM EXTERNAL PROVIDER');
END

IF NOT EXISTS (
    SELECT *
    FROM sys.database_role_members members
    INNER JOIN sys.database_principals roles ON members.role_principal_id = roles.principal_id
    INNER JOIN sys.database_principals users ON members.member_principal_id = users.principal_id
    WHERE roles.name = N'db_datareader' AND users.name = N'{managedIdentityLiteral}'
)
BEGIN
    EXEC(N'ALTER ROLE [db_datareader] ADD MEMBER {managedIdentityIdentifier}');
END

IF NOT EXISTS (
    SELECT *
    FROM sys.database_role_members members
    INNER JOIN sys.database_principals roles ON members.role_principal_id = roles.principal_id
    INNER JOIN sys.database_principals users ON members.member_principal_id = users.principal_id
    WHERE roles.name = N'db_datawriter' AND users.name = N'{managedIdentityLiteral}'
)
BEGIN
    EXEC(N'ALTER ROLE [db_datawriter] ADD MEMBER {managedIdentityIdentifier}');
END

IF OBJECT_ID(N'dbo.payment', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.payment
    (
        id int IDENTITY(1,1) NOT NULL CONSTRAINT PK_payment PRIMARY KEY,
        userId nvarchar(256) NULL,
        reservationId nvarchar(256) NULL,
        provider int NOT NULL,
        status int NOT NULL,
        amount decimal(18, 2) NOT NULL,
        currency nvarchar(16) NULL,
        createdAt datetime2 NOT NULL
    );
END;
";

        await command.ExecuteNonQueryAsync();
    }

    private static string QuoteSqlIdentifier(string value)
    {
        return $"[{value.Replace("]", "]]", StringComparison.Ordinal)}]";
    }

    private static string EscapeSqlLiteral(string value)
    {
        return value.Replace("'", "''", StringComparison.Ordinal);
    }

    

    private async Task<SqlConnection> Connect()
    {
        // e.g. "Server=tcp:<your-server-name>.database.windows.net,1433;Database=<your-database-name>;"
        string sqlConnectionString = _configuration["AZURE-SQL-CONNECTION-STRING-payments-api"];
        TokenCredential credential = EnvironmentExtensions.IsTestEnvironment() ? new AzureCliCredential() : new DefaultAzureCredential();
        var sqlConnection = new SqlConnection(sqlConnectionString);
        var accessToken = await credential.GetTokenAsync(new TokenRequestContext(new[] { "https://database.windows.net//.default" }), CancellationToken.None);
        sqlConnection.AccessToken = accessToken.Token;
        this._logger.LogInformation("SQL access token acquired.");
        await sqlConnection.OpenAsync();
        return sqlConnection;
    }

}

public class Payment
{
    public int Id { get; set; }
    public string UserId { get; set; }
    public string ReservationId { get; set; }
    public int Provider { get; set; }
    public int Status { get; set; }
    public decimal Amount { get; set; }
    public string Currency { get; set; }
    public DateTime CreatedAt { get; set; }
}

public enum PaymentStatus
{
    Pending = 1,
    Active = 2,
    Cancelled = 3,
    Complete = 4,
}