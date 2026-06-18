import Foundation
import CSQLiteVec

public enum IndexError: Error, CustomStringConvertible {
    case open(String)
    case sql(String)
    public var description: String {
        switch self {
        case .open(let m): return "打开索引失败：\(m)"
        case .sql(let m): return "SQL 失败：\(m)"
        }
    }
}

public struct SearchHit {
    public let rowid: Int64
    public let text: String
    public let recordingId: String
    public let start: Double
    public let end: Double
    public let score: Double   // 该路的分数（向量=距离；FTS=rank）
}

/// 派生索引：SQLite + FTS5(trigram) + sqlite-vec。向量存前 L2 归一化（L2 排序≈cosine）。
public final class Index {
    let db: OpaquePointer
    public let dim: Int

    public init(path: URL, dim: Int) throws {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK, let h = handle else {
            throw IndexError.open(path.path)
        }
        self.db = h
        self.dim = dim
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_vec_init(db, &err, nil) == SQLITE_OK else {
            throw IndexError.open("sqlite_vec_init: \(err.map { String(cString: $0) } ?? "?")")
        }
        try createSchema()
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            throw IndexError.sql("\(err.map { String(cString: $0) } ?? "?")")
        }
    }

    private func createSchema() throws {
        try exec("""
        create table if not exists meta(key text primary key, value text);
        create table if not exists recordings(
            id text primary key, title text, recorded_at text,
            duration_sec integer, source text, language text);
        create table if not exists chunks(
            id integer primary key, recording_id text, idx integer,
            text text, context text, start real, end real, person_id text);
        create virtual table if not exists chunks_fts using fts5(text, tokenize='trigram');
        create virtual table if not exists chunks_vec using vec0(embedding float[\(dim)]);
        create table if not exists enrichment_cache(hash text primary key, context text, model text);
        """)
    }

    // MARK: meta

    public func setMeta(_ key: String, _ value: String) throws {
        let sql = "insert into meta(key,value) values(?,?) on conflict(key) do update set value=excluded.value"
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, key); bindText(st, 2, value)
        guard sqlite3_step(st) == SQLITE_DONE else { throw IndexError.sql(lastErr()) }
    }

    // MARK: 写入

    public func upsertRecording(id: String, title: String, recordedAt: String,
                                durationSec: Int, source: String, language: String) throws {
        let sql = """
        insert into recordings(id,title,recorded_at,duration_sec,source,language)
        values(?,?,?,?,?,?)
        on conflict(id) do update set title=excluded.title, recorded_at=excluded.recorded_at,
            duration_sec=excluded.duration_sec, source=excluded.source, language=excluded.language
        """
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, id); bindText(st, 2, title); bindText(st, 3, recordedAt)
        sqlite3_bind_int64(st, 4, Int64(durationSec)); bindText(st, 5, source); bindText(st, 6, language)
        guard sqlite3_step(st) == SQLITE_DONE else { throw IndexError.sql(lastErr()) }
    }

    /// 删除某录音已有的 chunks（重建幂等）。
    public func deleteChunks(recordingId: String) throws {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "select id from chunks where recording_id=?", -1, &st, nil)
        bindText(st, 1, recordingId)
        var ids: [Int64] = []
        while sqlite3_step(st) == SQLITE_ROW { ids.append(sqlite3_column_int64(st, 0)) }
        sqlite3_finalize(st)
        for rid in ids {
            try exec("delete from chunks_fts where rowid=\(rid)")
            try exec("delete from chunks_vec where rowid=\(rid)")
        }
        try exec("delete from chunks where recording_id='\(recordingId.replacingOccurrences(of: "'", with: "''"))'")
    }

    public func insertChunk(recordingId: String, idx: Int, text: String, context: String?,
                            start: Double, end: Double, personId: String?,
                            embedding: [Float]) throws {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db,
            "insert into chunks(recording_id,idx,text,context,start,end,person_id) values(?,?,?,?,?,?,?)",
            -1, &st, nil)
        bindText(st, 1, recordingId); sqlite3_bind_int64(st, 2, Int64(idx))
        bindText(st, 3, text)
        if let c = context { bindText(st, 4, c) } else { sqlite3_bind_null(st, 4) }
        sqlite3_bind_double(st, 5, start); sqlite3_bind_double(st, 6, end)
        if let p = personId { bindText(st, 7, p) } else { sqlite3_bind_null(st, 7) }
        guard sqlite3_step(st) == SQLITE_DONE else { sqlite3_finalize(st); throw IndexError.sql(lastErr()) }
        sqlite3_finalize(st)
        let rowid = sqlite3_last_insert_rowid(db)

        // FTS（用 chunk 的可检索文本：有 context 用 context+text，否则 text）
        let ftsText = context.map { "\($0)\n\(text)" } ?? text
        var f: OpaquePointer?
        sqlite3_prepare_v2(db, "insert into chunks_fts(rowid,text) values(?,?)", -1, &f, nil)
        sqlite3_bind_int64(f, 1, rowid); bindText(f, 2, ftsText)
        guard sqlite3_step(f) == SQLITE_DONE else { sqlite3_finalize(f); throw IndexError.sql(lastErr()) }
        sqlite3_finalize(f)

        // 向量（归一化 → JSON）
        var v: OpaquePointer?
        sqlite3_prepare_v2(db, "insert into chunks_vec(rowid,embedding) values(?,?)", -1, &v, nil)
        sqlite3_bind_int64(v, 1, rowid); bindText(v, 2, vectorJSON(normalize(embedding)))
        guard sqlite3_step(v) == SQLITE_DONE else { sqlite3_finalize(v); throw IndexError.sql(lastErr()) }
        sqlite3_finalize(v)
    }

    // MARK: 检索

    public func vectorSearch(_ queryVec: [Float], k: Int) throws -> [SearchHit] {
        let sql = """
        select c.id, c.text, c.recording_id, c.start, c.end, v.distance
        from chunks_vec v join chunks c on c.id = v.rowid
        where v.embedding match ? and k = \(k) order by v.distance
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw IndexError.sql(lastErr()) }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, vectorJSON(normalize(queryVec)))
        return readHits(st)
    }

    public func ftsSearch(_ query: String, k: Int) throws -> [SearchHit] {
        let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "") + "\""
        let sql = """
        select c.id, c.text, c.recording_id, c.start, c.end, f.rank
        from chunks_fts f join chunks c on c.id = f.rowid
        where chunks_fts match ? order by f.rank limit \(k)
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw IndexError.sql(lastErr()) }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, phrase)
        return readHits(st)
    }

    private func readHits(_ st: OpaquePointer?) -> [SearchHit] {
        var hits: [SearchHit] = []
        while sqlite3_step(st) == SQLITE_ROW {
            hits.append(SearchHit(
                rowid: sqlite3_column_int64(st, 0),
                text: String(cString: sqlite3_column_text(st, 1)),
                recordingId: String(cString: sqlite3_column_text(st, 2)),
                start: sqlite3_column_double(st, 3),
                end: sqlite3_column_double(st, 4),
                score: sqlite3_column_double(st, 5)))
        }
        return hits
    }

    private func lastErr() -> String { String(cString: sqlite3_errmsg(db)) }
}

// SQLITE_TRANSIENT：让 SQLite 拷贝字符串，避免 Swift 字符串被释放。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private func bindText(_ st: OpaquePointer?, _ idx: Int32, _ s: String) {
    sqlite3_bind_text(st, idx, s, -1, SQLITE_TRANSIENT)
}

func normalize(_ v: [Float]) -> [Float] {
    let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
    return n > 0 ? v.map { $0 / n } : v
}

func vectorJSON(_ v: [Float]) -> String {
    "[" + v.map { String($0) }.joined(separator: ",") + "]"
}
