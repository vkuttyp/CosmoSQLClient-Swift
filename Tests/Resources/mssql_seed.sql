-- MSSQL seed data for sql-nio integration tests
-- Run against MSSQLNioTestDb before executing MSSQLNioTests

USE MSSQLNioTestDb;
GO

-- ─── Drop existing objects ────────────────────────────────────────────────────

IF OBJECT_ID('dbo.sp_PrintMessage',            'P') IS NOT NULL DROP PROCEDURE sp_PrintMessage;
IF OBJECT_ID('dbo.sp_GetEmployeeWithOutput',   'P') IS NOT NULL DROP PROCEDURE sp_GetEmployeeWithOutput;
IF OBJECT_ID('dbo.sp_GetMultipleResultSets',   'P') IS NOT NULL DROP PROCEDURE sp_GetMultipleResultSets;
IF OBJECT_ID('dbo.CompatRPC_StrProc',          'P') IS NOT NULL DROP PROCEDURE CompatRPC_StrProc;
IF OBJECT_ID('dbo.CompatRPC_SelectProc',       'P') IS NOT NULL DROP PROCEDURE CompatRPC_SelectProc;
IF OBJECT_ID('dbo.CompatRPC_NamedParams',      'P') IS NOT NULL DROP PROCEDURE CompatRPC_NamedParams;
IF OBJECT_ID('dbo.CompatRPC_IntProc',          'P') IS NOT NULL DROP PROCEDURE CompatRPC_IntProc;
IF OBJECT_ID('dbo.sp_GetEmployeesAsJSON',      'P') IS NOT NULL DROP PROCEDURE sp_GetEmployeesAsJSON;
IF OBJECT_ID('dbo.sp_GetDepartmentSummary',      'P') IS NOT NULL DROP PROCEDURE sp_GetDepartmentSummary;
IF OBJECT_ID('dbo.sp_InsertEmployee',            'P') IS NOT NULL DROP PROCEDURE sp_InsertEmployee;
IF OBJECT_ID('dbo.sp_GetEmployeesByDepartment',  'P') IS NOT NULL DROP PROCEDURE sp_GetEmployeesByDepartment;
IF OBJECT_ID('dbo.sp_GetEmployeeById',           'P') IS NOT NULL DROP PROCEDURE sp_GetEmployeeById;
IF OBJECT_ID('dbo.BulkTestTable', 'U') IS NOT NULL DROP TABLE BulkTestTable;
IF OBJECT_ID('dbo.LargeData',     'U') IS NOT NULL DROP TABLE LargeData;
IF OBJECT_ID('dbo.TypesTable',    'U') IS NOT NULL DROP TABLE TypesTable;
IF OBJECT_ID('dbo.Employees',     'U') IS NOT NULL DROP TABLE Employees;
IF OBJECT_ID('dbo.Departments',   'U') IS NOT NULL DROP TABLE Departments;
GO

-- ─── Departments ─────────────────────────────────────────────────────────────

CREATE TABLE Departments (
    id     INT IDENTITY(1,1) PRIMARY KEY,
    name   NVARCHAR(100) NOT NULL,
    budget DECIMAL(14,2) DEFAULT 0.00
);

INSERT INTO Departments (name, budget) VALUES
    ('Engineering', 1500000.00),
    ('Sales',        800000.50),
    ('HR',           400000.00),
    ('Operations',   600000.00),
    ('Marketing',    300000.00);

-- ─── Employees ───────────────────────────────────────────────────────────────
-- 5 employees total; 2 in dept=1 (Engineering)
-- Marketing (dept=5) has 0 employees for sp_GetEmployeesByDepartment dept=5 test

CREATE TABLE Employees (
    id            UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
    name          NVARCHAR(100)   NOT NULL,
    email         NVARCHAR(150)   NULL,
    salary        DECIMAL(10,2)   NOT NULL,
    department_id INT             NOT NULL REFERENCES Departments(id),
    is_active     BIT             DEFAULT 1,
    notes         NVARCHAR(MAX)   NULL,
    hire_date     DATE            NULL
);

-- Alphabetical order: Alice, Bob, Carol, Dave, Eve
-- dept=1 avg_salary = (95000 + 85000) / 2 = 90000
INSERT INTO Employees (name, email, salary, department_id, is_active, notes, hire_date) VALUES
    ('Alice Johnson', 'alice@example.com', 95000.00, 1, 1,
        'Senior engineer and team lead with 10 years of experience', '2015-03-01'),
    ('Bob Smith',     'bob@example.com',   85000.00, 1, 1,
        NULL, '2018-06-15'),
    ('Carol White',   NULL,                65000.00, 2, 1,
        NULL, '2019-01-10'),
    ('Dave Brown',    'dave@example.com',  55000.00, 3, 0,
        NULL, '2020-07-20'),
    ('Eve Davis',     'eve@example.com',   70000.00, 4, 1,
        NULL, '2021-09-05');

-- ─── TypesTable ──────────────────────────────────────────────────────────────

CREATE TABLE TypesTable (
    id                  INT IDENTITY(1,1) PRIMARY KEY,
    col_int             INT               NULL,
    col_int_null        INT               NULL,
    col_bigint          BIGINT            NULL,
    col_smallint        SMALLINT          NULL,
    col_tinyint         TINYINT           NULL,
    col_bit             BIT               NULL,
    col_bit_null        BIT               NULL,
    col_decimal         DECIMAL(12,4)     NULL,
    col_decimal_null    DECIMAL(10,2)     NULL,
    col_float           FLOAT             NULL,
    col_real            REAL              NULL,
    col_money           MONEY             NULL,
    col_smallmoney      SMALLMONEY        NULL,
    col_money_null      MONEY             NULL,
    col_smallmoney_null SMALLMONEY        NULL,
    col_datetime        DATETIME          NULL,
    col_datetime_null   DATETIME          NULL,
    col_smalldatetime   SMALLDATETIME     NULL,
    col_nvarchar        NVARCHAR(200)     NULL,
    col_nvarchar_null   NVARCHAR(200)     NULL,
    col_nvarchar_max    NVARCHAR(MAX)     NULL,
    col_varchar         VARCHAR(100)      NULL,
    col_uniqueidentifier UNIQUEIDENTIFIER NULL,
    col_uniqueid_null   UNIQUEIDENTIFIER  NULL,
    col_date            DATE              NULL,
    col_date_null       DATE              NULL,
    col_time            TIME(7)           NULL,
    col_time_null       TIME(7)           NULL,
    col_datetime2       DATETIME2(7)      NULL,
    col_datetime2_null  DATETIME2(7)      NULL,
    col_dtoffset        DATETIMEOFFSET(7) NULL,
    col_dtoffset_null   DATETIMEOFFSET    NULL,
    col_text            TEXT              NULL,
    col_ntext           NTEXT             NULL,
    col_image           IMAGE             NULL
);

-- Row 1: all non-null values
INSERT INTO TypesTable (
    col_int, col_int_null,
    col_bigint, col_smallint, col_tinyint,
    col_bit, col_bit_null,
    col_decimal, col_decimal_null,
    col_float, col_real,
    col_money, col_smallmoney, col_money_null, col_smallmoney_null,
    col_datetime, col_datetime_null,
    col_smalldatetime,
    col_nvarchar, col_nvarchar_null,
    col_nvarchar_max,
    col_varchar,
    col_uniqueidentifier, col_uniqueid_null,
    col_date, col_date_null,
    col_time, col_time_null,
    col_datetime2, col_datetime2_null,
    col_dtoffset, col_dtoffset_null,
    col_text, col_ntext, col_image
) VALUES (
    42, NULL,
    9223372036854775807, 32767, 255,
    1, NULL,
    12345.6789, NULL,
    3.14159265358979, 2.718,
    1234.5678, 99.99, 9.99, 1.23,
    '2024-01-15 10:30:00', NULL,
    '2024-01-15 10:30:00',
    N'Hello, World!', NULL,
    N'This is a test of NVARCHAR(MAX) column storing large content',
    'varchar_value',
    '6F9619FF-8B86-D011-B42D-00C04FC964FF', NULL,
    '2025-03-15', '2024-12-31',
    '13:45:30.1234567', NULL,
    '2025-03-15 13:45:30', '2025-01-01 00:00:00',
    CAST('2025-03-15 13:45:30.0000000 +05:30' AS DATETIMEOFFSET), NULL,
    'Hello from TEXT', N'Hello from NTEXT', 0xDEADBEEF
);

-- Row 2: null variants + edge-case values
INSERT INTO TypesTable (
    col_int, col_int_null,
    col_bigint, col_smallint, col_tinyint,
    col_bit, col_bit_null,
    col_decimal, col_decimal_null,
    col_float, col_real,
    col_money, col_smallmoney, col_money_null, col_smallmoney_null,
    col_datetime, col_datetime_null,
    col_smalldatetime,
    col_nvarchar, col_nvarchar_null,
    col_nvarchar_max,
    col_varchar,
    col_uniqueidentifier, col_uniqueid_null,
    col_date, col_date_null,
    col_time, col_time_null,
    col_datetime2, col_datetime2_null,
    col_dtoffset, col_dtoffset_null,
    col_text, col_ntext, col_image
) VALUES (
    200, 100,
    -9223372036854775808, -32768, 0,
    0, 1,
    0.0001, 99.99,
    1.0, 1.0,
    0.00, 0.00, NULL, NULL,
    '1900-01-01 00:00:00', '2099-12-31',
    '2000-01-01 00:00:00',
    N'Ünïcödé テスト 中文', NULL,
    NULL,
    'row2',
    '550E8400-E29B-41D4-A716-446655440001', '550E8400-E29B-41D4-A716-446655440000',
    '2000-01-01', NULL,
    '00:00:00', NULL,
    '2000-01-01 00:00:00', NULL,
    CAST('2000-01-01 00:00:00.0000000 +00:00' AS DATETIMEOFFSET), NULL,
    NULL, N'Row 2 ntext', 0x00
);

-- Update row 2 col_nvarchar_max to 5000 'X' chars (multi-packet PLP test)
DECLARE @big NVARCHAR(MAX) = REPLICATE(CAST(N'X' AS NVARCHAR(MAX)), 5000);
UPDATE TypesTable SET col_nvarchar_max = @big WHERE id = 2;
GO

-- ─── BulkTestTable ───────────────────────────────────────────────────────────

CREATE TABLE BulkTestTable (
    id     INT IDENTITY(1,1) PRIMARY KEY,
    name   NVARCHAR(100)  NOT NULL,
    amount DECIMAL(10,2)  NOT NULL,
    active BIT            DEFAULT 1
);
GO

-- ─── Stored Procedures ───────────────────────────────────────────────────────

CREATE PROCEDURE sp_GetEmployeeById
    @p1 UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT id, name, email, salary, department_id, is_active, notes
    FROM Employees
    WHERE id = @p1;
END;
GO

CREATE PROCEDURE sp_GetEmployeesByDepartment
    @p1 INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT id, name, email, salary, department_id, is_active, notes
    FROM Employees
    WHERE department_id = @p1
    ORDER BY name;
END;
GO

CREATE PROCEDURE sp_InsertEmployee
    @p1 NVARCHAR(100),
    @p2 NVARCHAR(150),
    @p3 INT,
    @p4 DECIMAL(10,2),
    @p5 DATE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO Employees (name, email, department_id, salary, hire_date)
    OUTPUT INSERTED.id
    VALUES (@p1, @p2, @p3, @p4, @p5);
END;
GO

CREATE PROCEDURE sp_GetDepartmentSummary
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        d.id,
        d.name,
        d.budget,
        COUNT(e.id)        AS employee_count,
        AVG(e.salary)      AS avg_salary
    FROM Departments d
    LEFT JOIN Employees e ON e.department_id = d.id
    GROUP BY d.id, d.name, d.budget
    ORDER BY d.id;
END;
GO

CREATE PROCEDURE sp_GetEmployeesAsJSON
AS
BEGIN
    SET NOCOUNT ON;
    SELECT id, name, email, salary, department_id, is_active
    FROM Employees
    ORDER BY name
    FOR JSON PATH;
END;
GO

-- ─── LargeData ───────────────────────────────────────────────────────────────

CREATE TABLE LargeData (
    id      INT IDENTITY(1,1) PRIMARY KEY,
    payload NVARCHAR(MAX) NOT NULL,
    label   NVARCHAR(100) NOT NULL
);
GO

-- ─── LargeData seed rows ─────────────────────────────────────────────────────

DECLARE @p3k  NVARCHAR(MAX) = REPLICATE(CAST(N'A' AS NVARCHAR(MAX)),  3000);
DECLARE @p5k  NVARCHAR(MAX) = REPLICATE(CAST(N'B' AS NVARCHAR(MAX)),  5000);
DECLARE @p10k NVARCHAR(MAX) = REPLICATE(CAST(N'C' AS NVARCHAR(MAX)), 10000);
INSERT INTO LargeData (payload, label) VALUES
    (@p3k,  N'medium_3000'),
    (@p5k,  N'large_5000'),
    (@p10k, N'xlarge_10000');
GO

-- ─── Additional Stored Procedures ────────────────────────────────────────────

CREATE PROCEDURE sp_GetMultipleResultSets
AS
BEGIN
    SELECT id, name FROM Departments ORDER BY id;
    SELECT id, name, department_id FROM Employees ORDER BY id;
END;
GO

CREATE PROCEDURE sp_GetEmployeeWithOutput
    @EmployeeId      UNIQUEIDENTIFIER,
    @FullName        NVARCHAR(200) OUTPUT,
    @DepartmentName  NVARCHAR(100) OUTPUT
AS
BEGIN
    SELECT @FullName = e.name,
           @DepartmentName = d.name
    FROM Employees e
    JOIN Departments d ON e.department_id = d.id
    WHERE e.id = @EmployeeId;
    RETURN 0;
END;
GO

CREATE PROCEDURE sp_PrintMessage @Msg NVARCHAR(500)
AS
BEGIN
    PRINT @Msg;
END;
GO

CREATE PROCEDURE CompatRPC_IntProc @InVal INT, @OutVal INT OUTPUT
AS
BEGIN
    SET @OutVal = @InVal * 2;
    RETURN 77;
END;
GO

CREATE PROCEDURE CompatRPC_NamedParams @Val INT, @Str NVARCHAR(50)
AS
BEGIN
    SELECT @Val + 1 AS Result, @Str AS Msg;
END;
GO

CREATE PROCEDURE CompatRPC_SelectProc @N INT
AS
BEGIN
    SELECT @N AS Val, @N * 2 AS [Double];
END;
GO

CREATE PROCEDURE CompatRPC_StrProc @InStr NVARCHAR(50), @OutStr NVARCHAR(50) OUTPUT
AS
BEGIN
    SET @OutStr = N'Hello ' + @InStr;
END;
GO
