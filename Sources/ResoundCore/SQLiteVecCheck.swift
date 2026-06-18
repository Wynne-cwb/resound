import Foundation
import CSQLiteVec

public enum SQLiteVecError: Error, CustomStringConvertible {
    case message(String)
    public var description: String {
        switch self { case .message(let m): return m }
    }
}

/// 验证 sqlite-vec 在本机能静态注册并跑通 KNN。返回诊断信息。
public func sqliteVecSmokeTest() throws -> String {
    var db: OpaquePointer?
    guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
        throw SQLiteVecError.message("打开内存数据库失败")
    }
    defer { sqlite3_close(db) }

    // 静态注册 sqlite-vec（SQLITE_CORE 模式，无需加载扩展）
    var errPtr: UnsafeMutablePointer<CChar>?
    guard sqlite3_vec_init(db, &errPtr, nil) == SQLITE_OK else {
        let m = errPtr.map { String(cString: $0) } ?? "未知"
        throw SQLiteVecError.message("sqlite3_vec_init 失败：\(m)")
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "未知"
            throw SQLiteVecError.message("SQL 失败：\(m)\nSQL: \(sql)")
        }
    }

    // vec_version()
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "select vec_version()", -1, &stmt, nil) == SQLITE_OK,
          sqlite3_step(stmt) == SQLITE_ROW,
          let cstr = sqlite3_column_text(stmt, 0) else {
        throw SQLiteVecError.message("读取 vec_version 失败")
    }
    let version = String(cString: cstr)
    sqlite3_finalize(stmt)

    // 建 vec0 表（4 维），插 3 条，做 KNN
    try exec("create virtual table v using vec0(embedding float[4])")
    try exec("""
        insert into v(rowid, embedding) values
        (1, '[1.0, 0.0, 0.0, 0.0]'),
        (2, '[0.0, 1.0, 0.0, 0.0]'),
        (3, '[0.9, 0.1, 0.0, 0.0]')
    """)

    var q: OpaquePointer?
    let sql = "select rowid, distance from v where embedding match '[1.0,0.0,0.0,0.0]' and k = 2 order by distance"
    guard sqlite3_prepare_v2(db, sql, -1, &q, nil) == SQLITE_OK else {
        throw SQLiteVecError.message("KNN 查询 prepare 失败：\(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(q) }

    var hits: [(Int64, Double)] = []
    while sqlite3_step(q) == SQLITE_ROW {
        hits.append((sqlite3_column_int64(q, 0), sqlite3_column_double(q, 1)))
    }
    guard hits.first?.0 == 1 else {
        throw SQLiteVecError.message("KNN 结果异常：\(hits)")
    }

    let near = hits.map { "rowid=\($0.0) dist=\(String(format: "%.4f", $0.1))" }.joined(separator: ", ")
    return """
    sqlite-vec OK
      vec_version: \(version)
      sqlite: \(String(cString: sqlite3_libversion()))
      KNN top2: \(near)
    """
}
