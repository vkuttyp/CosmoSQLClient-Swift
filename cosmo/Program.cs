// See https://aka.ms/new-console-template for more information
using CosmoSQLClient.Core;
using CosmoSQLClient.MsSql;

Console.WriteLine("Hello, World!");
await using var conn = await MsSqlConnection.OpenAsync(
    "Server=localhost,1433;Database=MurshiDb;User Id=sa;Password=aBCD111;Encrypt=True;TrustServerCertificate=True;");

var table = await conn.QueryTableAsync("SELECT TOP 3 AccountNo, AccountName, AccountTypeID, IsMain FROM Accounts");

Console.WriteLine(table.ToJson());

public class Account
{
    public string? AccountNo { get; set; }
    public string? AccountName { get; set; }
    public int AccountTypeID { get; set; }
    public bool IsMain { get; set; }
}
