/*
    02_CreateTables.sql

    Creates Customers, Orders, keys, the foreign key, and dbo.DemoSettings.
    The nonclustered CustomerId index is created in 04_CreateIndexes.sql after the load.
    This script changes only SqlServerOPPODemo.

    DemoSettings is the single place to resize the data set before 03_GenerateData.sql.
    Limits keep the generator inside the set-based number table (maximum 1,000,000 orders).
*/
USE SqlServerOPPODemo;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF DB_NAME() <> N'SqlServerOPPODemo'
    THROW 50020, 'Refusing to create tables because the current database is not SqlServerOPPODemo.', 1;

IF OBJECT_ID(N'dbo.Orders', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Orders
    (
        OrderId int NOT NULL,
        CustomerId int NOT NULL,
        OrderDate datetime2(0) NOT NULL,
        OrderStatus nvarchar(20) NOT NULL,
        TotalAmount decimal(18, 2) NOT NULL,
        CreatedAt datetime2(0) NOT NULL,
        CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderId)
    );
END;

IF OBJECT_ID(N'dbo.Customers', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Customers
    (
        CustomerId int NOT NULL,
        CustomerName nvarchar(200) NOT NULL,
        CustomerType nvarchar(30) NOT NULL,
        CreatedAt datetime2(0) NOT NULL,
        CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED (CustomerId)
    );
END;
GO

IF OBJECT_ID(N'dbo.FK_Orders_Customers', N'F') IS NULL
   AND OBJECT_ID(N'dbo.Orders', N'U') IS NOT NULL
   AND OBJECT_ID(N'dbo.Customers', N'U') IS NOT NULL
BEGIN
    ALTER TABLE dbo.Orders
        ADD CONSTRAINT FK_Orders_Customers
        FOREIGN KEY (CustomerId) REFERENCES dbo.Customers (CustomerId);
END;
GO

IF OBJECT_ID(N'dbo.DemoSettings', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DemoSettings
    (
        SettingsId int NOT NULL,
        CustomerCount int NOT NULL,
        OrderCount int NOT NULL,
        SelectiveCustomerId int NOT NULL,
        SelectiveOrderCount int NOT NULL,
        MeasuredRuns int NOT NULL,
        CONSTRAINT PK_DemoSettings PRIMARY KEY CLUSTERED (SettingsId),
        CONSTRAINT CK_DemoSettings_OneRow CHECK (SettingsId = 1),
        CONSTRAINT CK_DemoSettings_Range CHECK
        (
            CustomerCount BETWEEN 125 AND 50000
            AND OrderCount BETWEEN 50000 AND 1000000
            AND OrderCount >= CustomerCount * 5
            AND SelectiveCustomerId BETWEEN 1 AND CustomerCount
            AND SelectiveOrderCount BETWEEN 1 AND 1000
            AND SelectiveOrderCount * 50 <= OrderCount
            AND MeasuredRuns BETWEEN 1 AND 10
        )
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.DemoSettings WHERE SettingsId = 1)
BEGIN
    INSERT dbo.DemoSettings
    (
        SettingsId,
        CustomerCount,
        OrderCount,
        SelectiveCustomerId,
        SelectiveOrderCount,
        MeasuredRuns
    )
    VALUES
    (
        1,
        10000,
        500000,
        125,
        20,
        5
    );
END;
GO

PRINT N'Tables are ready. Current demo settings:';
SELECT
    CustomerCount,
    OrderCount,
    SelectiveCustomerId,
    SelectiveOrderCount,
    MeasuredRuns
FROM dbo.DemoSettings
WHERE SettingsId = 1;
GO
