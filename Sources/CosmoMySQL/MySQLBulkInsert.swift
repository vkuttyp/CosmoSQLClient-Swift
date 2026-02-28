import CosmoSQLCore

// MARK: - MySQLConnection bulk insert

extension MySQLConnection {

    /// Insert multiple rows into `table` in batches.
    ///
    /// - Parameters:
    ///   - table:   Target table name (will be backtick-quoted).
    ///   - columns: Ordered list of column names.
    ///   - rows:    Each element is a row of values parallel to `columns`.
    /// - Returns:  Total number of rows inserted.
    @discardableResult
    public func bulkInsert(
        table:   String,
        columns: [String],
        rows:    [[SQLValue]]
    ) async throws -> Int {
        guard !rows.isEmpty, !columns.isEmpty else { return 0 }

        // MySQL inline param limit is effectively limited by max_allowed_packet.
        // Use 500 rows per batch as a safe default.
        let batchSize = 500

        let colList = columns.map { "`\($0)`" }.joined(separator: ", ")
        var totalInserted = 0
        var offset = 0

        while offset < rows.count {
            let batch = Array(rows[offset ..< min(offset + batchSize, rows.count)])
            offset += batchSize

            var valueClauses: [String] = []
            var params: [SQLValue] = []

            for row in batch {
                // MySQL uses ? placeholders
                let placeholders = row.indices.map { _ in "?" }.joined(separator: ", ")
                valueClauses.append("(\(placeholders))")
                params.append(contentsOf: row)
            }

            let sql = "INSERT INTO `\(table)` (\(colList)) VALUES \(valueClauses.joined(separator: ", "))"
            let inserted = try await execute(sql, params)
            totalInserted += inserted
        }

        return totalInserted
    }

    /// Insert multiple rows supplied as dictionaries.
    ///
    /// Column order is derived from the keys of the first row.
    @discardableResult
    public func bulkInsert(
        table: String,
        rows:  [[String: SQLValue]]
    ) async throws -> Int {
        guard let first = rows.first else { return 0 }
        let columns   = Array(first.keys)
        let valueRows = rows.map { dict in columns.map { dict[$0] ?? .null } }
        return try await bulkInsert(table: table, columns: columns, rows: valueRows)
    }
}
