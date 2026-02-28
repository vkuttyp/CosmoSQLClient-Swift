// See https://aka.ms/new-console-template for more information
using CosmoSQLClient.Core;
using CosmoSQLClient.MsSql;

Console.WriteLine("Hello, World!");
var host = Environment.GetEnvironmentVariable("MSSQL_HOST") ?? "localhost";
var db   = Environment.GetEnvironmentVariable("MSSQL_DB")   ?? "MurshiDb";
var user = Environment.GetEnvironmentVariable("MSSQL_USER") ?? "sa";
var pass = Environment.GetEnvironmentVariable("MSSQL_PASS") ?? "";
await using var conn = await MsSqlConnection.OpenAsync(
    $"Server={host},1433;Database={db};User Id={user};Password={pass};Encrypt=True;TrustServerCertificate=True;");

var table = await conn.QueryTableAsync("SELECT TOP 3 AccountNo, AccountName, AccountTypeID, IsMain FROM Accounts");

Console.WriteLine(table.ToJson());

public class Account
{
    public string? AccountNo { get; set; }
    public string? AccountName { get; set; }
    public int AccountTypeID { get; set; }
    public bool IsMain { get; set; }
}
