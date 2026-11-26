/*
    04_CreateIndexes.sql

    Nonclustered index for selective customer searches.
    OrderId is the clustered key, so it is present at the leaf of this index
    without being listed in INCLUDE. The search query returns OrderId,
    CustomerId, OrderDate, and TotalAmount, so OrderDate and TotalAmount are included.
    OrderStatus is not part of that query and is not included.

    Run after 03_GenerateData.sql. Statistics are updated with FULLSCAN.
*/
USE SqlServerOPPODemo;
GO

SET NOCOUNT ON;

IF DB_NAME() <> N'SqlServerOPPODemo'
    THROW 50040, 'Refusing to create indexes because the current database is not SqlServerOPPODemo.', 1;

IF NOT EXISTS (SELECT 1 FROM dbo.Orders)
    THROW 50041, 'dbo.Orders is empty. Run 03_GenerateData.sql before creating the search index.', 1;

DROP INDEX IF EXISTS IX_Orders_CustomerId ON dbo.Orders;

CREATE NONCLUSTERED INDEX IX_Orders_CustomerId
    ON dbo.Orders (CustomerId)
    INCLUDE (OrderDate, TotalAmount);

UPDATE STATISTICS dbo.Customers WITH FULLSCAN;
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;

PRINT N'Index IX_Orders_CustomerId is created and statistics were updated with FULLSCAN.';

SELECT
    i.name AS IndexName,
    i.type_desc AS IndexType,
    c.name AS ColumnName,
    ic.key_ordinal,
    ic.is_included_column
FROM sys.indexes AS i
INNER JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id
   AND ic.index_id = i.index_id
INNER JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'dbo.Orders')
ORDER BY i.index_id, ic.key_ordinal, ic.index_column_id;
GO
