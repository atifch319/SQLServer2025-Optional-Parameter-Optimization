/*
    03_GenerateData.sql

    Deterministic, set-based load. Batch inserts read a number table built once.
    Customer 125 is the default selective customer and receives SelectiveOrderCount orders.
    Other orders are skewed: about half land on customers 1-50, about 40 percent on
    customers 51-500, and the rest on higher customer ids. Any bucket that would hit
    the selective customer is moved aside so that customer's row count stays exact.

    Change dbo.DemoSettings before running this script to resize the data set.
    The script reloads when it is run again. It writes only to SqlServerOPPODemo.
*/
USE SqlServerOPPODemo;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'SqlServerOPPODemo'
    THROW 50030, 'Refusing to load data because the current database is not SqlServerOPPODemo.', 1;

DECLARE @CustomerCount int;
DECLARE @OrderCount int;
DECLARE @SelectiveCustomerId int;
DECLARE @SelectiveOrderCount int;
DECLARE @SafeCustomerId int;
DECLARE @NonSelectiveOrders int;
DECLARE @BatchStart int;
DECLARE @BatchEnd int;
DECLARE @BatchSize int = 100000;
DECLARE @Epoch datetime2(0) = CONVERT(datetime2(0), '20230101', 112);
DECLARE @CustomerEpoch datetime2(0) = CONVERT(datetime2(0), '20240601', 112);

SELECT
    @CustomerCount = CustomerCount,
    @OrderCount = OrderCount,
    @SelectiveCustomerId = SelectiveCustomerId,
    @SelectiveOrderCount = SelectiveOrderCount
FROM dbo.DemoSettings
WHERE SettingsId = 1;

IF @CustomerCount IS NULL
    THROW 50031, 'dbo.DemoSettings has no row. Run 02_CreateTables.sql.', 1;

SET @SafeCustomerId = CASE WHEN @SelectiveCustomerId = 1 THEN 2 ELSE 1 END;
SET @NonSelectiveOrders = @OrderCount - @SelectiveOrderCount;

IF @OrderCount < 100000
    PRINT N'Warning: OrderCount is below 100,000. OPPO eligibility depends on cardinality and may not engage.';

PRINT N'Reloading deterministic data.';
PRINT CONCAT(N'Customers=', @CustomerCount, N' Orders=', @OrderCount,
    N' SelectiveCustomerId=', @SelectiveCustomerId,
    N' SelectiveOrderCount=', @SelectiveOrderCount);

IF OBJECT_ID(N'dbo.FK_Orders_Customers', N'F') IS NOT NULL
    ALTER TABLE dbo.Orders DROP CONSTRAINT FK_Orders_Customers;

TRUNCATE TABLE dbo.Orders;
DELETE FROM dbo.Customers;

IF OBJECT_ID(N'tempdb..#Numbers') IS NOT NULL
    DROP TABLE #Numbers;

CREATE TABLE #Numbers
(
    n int NOT NULL PRIMARY KEY
);

;WITH d AS
(
    SELECT n
    FROM (VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9)) AS v(n)
)
INSERT #Numbers (n)
SELECT
    d0.n
    + d1.n * 10
    + d2.n * 100
    + d3.n * 1000
    + d4.n * 10000
    + d5.n * 100000
    + 1
FROM d AS d0
CROSS JOIN d AS d1
CROSS JOIN d AS d2
CROSS JOIN d AS d3
CROSS JOIN d AS d4
CROSS JOIN d AS d5;

DELETE FROM #Numbers
WHERE n > @OrderCount;

INSERT dbo.Customers (CustomerId, CustomerName, CustomerType, CreatedAt)
SELECT
    n.n,
    CONCAT(N'Customer ', n.n),
    CASE n.n % 4
        WHEN 1 THEN N'Retail'
        WHEN 2 THEN N'Wholesale'
        WHEN 3 THEN N'Partner'
        ELSE N'Internal'
    END,
    DATEADD(DAY, -(n.n % 3650), @CustomerEpoch)
FROM #Numbers AS n
WHERE n.n <= @CustomerCount;

SET @BatchStart = 1;
WHILE @BatchStart <= @OrderCount
BEGIN
    SET @BatchEnd = @BatchStart + @BatchSize - 1;
    IF @BatchEnd > @OrderCount
        SET @BatchEnd = @OrderCount;

    INSERT dbo.Orders (OrderId, CustomerId, OrderDate, OrderStatus, TotalAmount, CreatedAt)
    SELECT
        nums.n,
        assigned.CustomerId,
        DATEADD(MINUTE, nums.n % 525600, @Epoch),
        CASE nums.n % 5
            WHEN 0 THEN N'Pending'
            WHEN 1 THEN N'Paid'
            WHEN 2 THEN N'Shipped'
            WHEN 3 THEN N'Completed'
            ELSE N'Cancelled'
        END,
        CONVERT(decimal(18, 2), 1.00 + (nums.n % 40000) * 0.25),
        DATEADD(SECOND, 5, DATEADD(MINUTE, nums.n % 525600, @Epoch))
    FROM #Numbers AS nums
    CROSS APPLY
    (
        SELECT CASE
            WHEN nums.n > @NonSelectiveOrders THEN @SelectiveCustomerId
            WHEN @CustomerCount < 600 THEN 1 + ((nums.n - 1) % (@CustomerCount - 1))
            WHEN nums.n % 100 < 50 THEN 1 + (nums.n % 50)
            WHEN nums.n % 100 < 90 THEN 51 + (nums.n % 450)
            ELSE 501 + (nums.n % (@CustomerCount - 501))
        END AS RawCustomerId
    ) AS raw
    CROSS APPLY
    (
        SELECT CASE
            WHEN nums.n > @NonSelectiveOrders THEN @SelectiveCustomerId
            WHEN raw.RawCustomerId = @SelectiveCustomerId THEN @SafeCustomerId
            WHEN raw.RawCustomerId < 1 OR raw.RawCustomerId > @CustomerCount THEN @SafeCustomerId
            ELSE raw.RawCustomerId
        END AS CustomerId
    ) AS assigned
    WHERE nums.n BETWEEN @BatchStart AND @BatchEnd;

    PRINT CONCAT(N'Loaded orders ', @BatchStart, N' through ', @BatchEnd, N'.');
    SET @BatchStart += @BatchSize;
END;

ALTER TABLE dbo.Orders
    ADD CONSTRAINT FK_Orders_Customers
    FOREIGN KEY (CustomerId) REFERENCES dbo.Customers (CustomerId);

IF (SELECT COUNT(*) FROM dbo.Customers) <> @CustomerCount
    THROW 50032, 'Customer row count does not match dbo.DemoSettings.', 1;

IF (SELECT COUNT(*) FROM dbo.Orders) <> @OrderCount
    THROW 50033, 'Order row count does not match dbo.DemoSettings.', 1;

IF (SELECT COUNT(*) FROM dbo.Orders WHERE CustomerId = @SelectiveCustomerId) <> @SelectiveOrderCount
    THROW 50034, 'Selective customer order count does not match dbo.DemoSettings.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.Orders AS o
    LEFT JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
    WHERE c.CustomerId IS NULL
)
    THROW 50035, 'Orders contain a CustomerId that is not in dbo.Customers.', 1;

IF
(
    SELECT MAX(bucket.OrderRows)
    FROM
    (
        SELECT COUNT_BIG(*) AS OrderRows
        FROM dbo.Orders
        GROUP BY CustomerId
    ) AS bucket
) <= @SelectiveOrderCount
    THROW 50036, 'Order distribution has no customer with more orders than the selective customer.', 1;

UPDATE STATISTICS dbo.Customers WITH FULLSCAN;
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;
CHECKPOINT;

PRINT N'Data load finished.';

SELECT
    (SELECT COUNT_BIG(*) FROM dbo.Customers) AS CustomerRows,
    (SELECT COUNT_BIG(*) FROM dbo.Orders) AS OrderRows,
    (SELECT COUNT_BIG(*) FROM dbo.Orders WHERE CustomerId = @SelectiveCustomerId) AS SelectiveCustomerOrders;

SELECT
    COUNT_BIG(*) AS CustomersWithOrders,
    MIN(bucket.OrderRows) AS MinOrdersPerCustomer,
    MAX(bucket.OrderRows) AS MaxOrdersPerCustomer,
    AVG(bucket.OrderRows) AS AvgOrdersPerCustomerWithOrders
FROM
(
    SELECT COUNT_BIG(*) AS OrderRows
    FROM dbo.Orders
    GROUP BY CustomerId
) AS bucket;

SELECT TOP (10)
    o.CustomerId,
    COUNT_BIG(*) AS OrderRows
FROM dbo.Orders AS o
GROUP BY o.CustomerId
ORDER BY COUNT_BIG(*) DESC, o.CustomerId ASC;
GO
