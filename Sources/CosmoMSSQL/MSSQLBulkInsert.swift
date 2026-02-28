import CosmoSQLCore

// MARK: - MSSQLConnection bulk insert

extension MSSQLConnection {

    /// Insert multiple rows into `table` in batches using multi-row INSERT / sp_executesql.
    ///
    /// - Parameters:
    ///   - table:   Target table name (will be bracket-quoted).
    ///   - columns: Ordered list of column names to insert into.
    ///   - rows:    Each element is a row of values parallel to `columns`.
    /// - Returns:  Total number of rows inserted.
    @discardableResult
    public func bulkInsert(
        table:   String,
        columns: [String],
        rows:    [[SQLValue]]
    ) async throws -> Int {
        guard !rows.isEmpty, !columns.isEmpty else { return 0 }

        // SQL Server allows up to ~2100 parameters per batch (sp_executesql limit).
        let maxParams = 2000
        let batchSize = max(1, maxParams / columns.count)

        let colList = columns.map { "[\($0)]" }.joined(separator: ", ")
        var totalInserted = 0

        var offset = 0
        while offset < rows.count {
            let batch = Array(rows[offset ..< min(offset + batchSize, rows.count)])
            offset += batchSize

            // Build: INSERT INTO [table] (col1, col2, ...) VALUES (@p1,@p2,...), (@p3,@p4,...), ...
            var paramIdx = 1
            var valueClauses: [String] = []
            var params: [SQLValue] = []

            for row in batch {
                let placeholders = row.indices.map { _ -> String in
                    defer { paramIdx += 1 }
                    return "@p\(paramIdx)"
                }.joined(separator: ", ")
                valueClauses.append("(\(placeholders))")
                params.append(contentsOf: row)
            }

            let sql = "INSERT INTO [\(table)] (\(colList)) VALUES \(valueClauses.joined(separator: ", "))"
            let inserted = try await execute(sql, params)
            totalInserted += inserted
        }

        return totalInserted
    }

    /// Insert multiple rows supplied as dictionaries.
    ///
    /// Column order is derived from the keys of the first row.
    /// All subsequent rows must contain the same keys.
    @discardableResult
    public func bulkInsert(
        table: String,
        rows:  [[String: SQLValue]]
    ) async throws -> Int {
        guard let first = rows.first else { return 0 }
        let columns = Array(first.keys)
        let valueRows = rows.map { dict in columns.map { dict[$0] ?? .null } }
        return try await bulkInsert(table: table, columns: columns, rows: valueRows)
    }
}
