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
    public let personId: String?   // 说话人（声纹识别填；nil=未标注/unknown）
    public let recordingDate: String?   // 录音本地日期 yyyy-MM-dd（时间检索/引用用）
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
        create table if not exists speaker_refs(name text primary key, count integer, vec text);
        """)
        // 增量迁移（旧库 create-if-not-exists 不会加新列）。
        addColumnIfMissing(table: "chunks", column: "recording_date", decl: "text")
        addColumnIfMissing(table: "recordings", column: "summary", decl: "text")
        addColumnIfMissing(table: "recordings", column: "summary_template", decl: "text")
    }

    /// 若列不存在则 ALTER TABLE 加上（幂等，便于旧索引平滑升级）。
    private func addColumnIfMissing(table: String, column: String, decl: String) {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "pragma table_info(\(table))", -1, &st, nil)
        var exists = false
        while sqlite3_step(st) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(st, 1)) == column { exists = true }
        }
        sqlite3_finalize(st)
        if !exists { try? exec("alter table \(table) add column \(column) \(decl)") }
    }

    // MARK: 声纹库（派生：参考声纹向量由 vault 标注重算；用户决定向量存 index）

    public func upsertSpeakerRef(name: String, count: Int, centroid: [Float]) throws {
        let sql = """
        insert into speaker_refs(name,count,vec) values(?,?,?)
        on conflict(name) do update set count=excluded.count, vec=excluded.vec
        """
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, name); sqlite3_bind_int64(st, 2, Int64(count)); bindText(st, 3, vectorJSON(centroid))
        guard sqlite3_step(st) == SQLITE_DONE else { throw IndexError.sql(lastErr()) }
    }

    public func loadSpeakerRefs() -> [SpeakerRef] {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "select name,count,vec from speaker_refs", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        var out: [SpeakerRef] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(st, 0))
            let count = Int(sqlite3_column_int64(st, 1))
            let vecStr = String(cString: sqlite3_column_text(st, 2))
            let centroid = vecStr.dropFirst().dropLast().split(separator: ",").compactMap { Float($0) }
            out.append(SpeakerRef(name: name, centroid: centroid, count: count))
        }
        return out
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

    // MARK: contextual 缓存（LLM 派生，按 hash 缓存避免重复付费/保证可复现）

    public func cachedContext(hash: String) -> String? {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "select context from enrichment_cache where hash=?", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, hash)
        if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
            return String(cString: c)
        }
        return nil
    }

    public func setCachedContext(hash: String, context: String, model: String) throws {
        let sql = """
        insert into enrichment_cache(hash,context,model) values(?,?,?)
        on conflict(hash) do update set context=excluded.context, model=excluded.model
        """
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, hash); bindText(st, 2, context); bindText(st, 3, model)
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
                            recordingDate: String?, embedding: [Float]) throws {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db,
            "insert into chunks(recording_id,idx,text,context,start,end,person_id,recording_date) values(?,?,?,?,?,?,?,?)",
            -1, &st, nil)
        bindText(st, 1, recordingId); sqlite3_bind_int64(st, 2, Int64(idx))
        bindText(st, 3, text)
        if let c = context { bindText(st, 4, c) } else { sqlite3_bind_null(st, 4) }
        sqlite3_bind_double(st, 5, start); sqlite3_bind_double(st, 6, end)
        if let p = personId { bindText(st, 7, p) } else { sqlite3_bind_null(st, 7) }
        if let d = recordingDate { bindText(st, 8, d) } else { sqlite3_bind_null(st, 8) }
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

    // MARK: 就地打说话人标签（不重嵌入；注册新声纹后可重打标）

    public func chunkTimes(recordingId: String) -> [(id: Int64, start: Double, end: Double)] {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "select id,start,end from chunks where recording_id=?", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, recordingId)
        var out: [(Int64, Double, Double)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((sqlite3_column_int64(st, 0), sqlite3_column_double(st, 1), sqlite3_column_double(st, 2)))
        }
        return out
    }

    public func setChunkPerson(id: Int64, person: String?) throws {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "update chunks set person_id=? where id=?", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        if let p = person { bindText(st, 1, p) } else { sqlite3_bind_null(st, 1) }
        sqlite3_bind_int64(st, 2, id)
        guard sqlite3_step(st) == SQLITE_DONE else { throw IndexError.sql(lastErr()) }
    }

    /// 某录音的 chunk 时间段 + 说话人（供录音库按段显示 👤；person 可能 nil）。
    public func chunkPersons(recordingId: String) -> [(start: Double, end: Double, person: String?)] {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "select start,end,person_id from chunks where recording_id=? order by start", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, recordingId)
        var out: [(Double, Double, String?)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let p = sqlite3_column_text(st, 2).map { String(cString: $0) }
            out.append((sqlite3_column_double(st, 0), sqlite3_column_double(st, 1), p))
        }
        return out
    }

    /// 删除某录音的全部索引数据（chunks + recordings 行）。
    public func deleteRecording(id: String) throws {
        try deleteChunks(recordingId: id)
        try exec("delete from recordings where id='\(id.replacingOccurrences(of: "'", with: "''"))'")
    }

    public func allRecordingIds() -> [String] {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "select id from recordings", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        var out: [String] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(st, 0))) }
        return out
    }

    // MARK: 检索

    /// 时间范围（含端点，本地 yyyy-MM-dd）。
    public typealias DateRange = (from: String, to: String)

    public func vectorSearch(_ queryVec: [Float], k: Int, dateRange: DateRange? = nil) throws -> [SearchHit] {
        // vec0 的 KNN 不支持前置过滤：带日期时把候选放大，过滤后仍够用（个人 wiki 规模可接受）。
        let knnK = dateRange == nil ? k : max(k, 4000)
        let dateClause = dateRange == nil ? "" : "and c.recording_date between ? and ?"
        let sql = """
        select c.id, c.text, c.recording_id, c.start, c.end, v.distance, c.person_id, c.recording_date
        from chunks_vec v join chunks c on c.id = v.rowid
        where v.embedding match ? and k = \(knnK) \(dateClause) order by v.distance limit \(k)
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw IndexError.sql(lastErr()) }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, vectorJSON(normalize(queryVec)))
        if let r = dateRange { bindText(st, 2, r.from); bindText(st, 3, r.to) }
        return readHits(st)
    }

    public func ftsSearch(_ query: String, k: Int, dateRange: DateRange? = nil) throws -> [SearchHit] {
        let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "") + "\""
        let dateClause = dateRange == nil ? "" : "and c.recording_date between ? and ?"
        let sql = """
        select c.id, c.text, c.recording_id, c.start, c.end, f.rank, c.person_id, c.recording_date
        from chunks_fts f join chunks c on c.id = f.rowid
        where chunks_fts match ? \(dateClause) order by f.rank limit \(k)
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw IndexError.sql(lastErr()) }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, phrase)
        if let r = dateRange { bindText(st, 2, r.from); bindText(st, 3, r.to) }
        return readHits(st)
    }

    private func readHits(_ st: OpaquePointer?) -> [SearchHit] {
        var hits: [SearchHit] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let person = sqlite3_column_text(st, 6).map { String(cString: $0) }
            let date = sqlite3_column_text(st, 7).map { String(cString: $0) }
            hits.append(SearchHit(
                rowid: sqlite3_column_int64(st, 0),
                text: String(cString: sqlite3_column_text(st, 1)),
                recordingId: String(cString: sqlite3_column_text(st, 2)),
                start: sqlite3_column_double(st, 3),
                end: sqlite3_column_double(st, 4),
                score: sqlite3_column_double(st, 5),
                personId: person,
                recordingDate: date))
        }
        return hits
    }

    // MARK: 录音级摘要 + 时间筛选（digest 模式用）

    public func setRecordingSummary(id: String, summary: String, template: String?) throws {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "update recordings set summary=?, summary_template=? where id=?", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, summary)
        if let t = template { bindText(st, 2, t) } else { sqlite3_bind_null(st, 2) }
        bindText(st, 3, id)
        guard sqlite3_step(st) == SQLITE_DONE else { throw IndexError.sql(lastErr()) }
    }

    public struct RecordingRow {
        public let id: String
        public let title: String
        public let recordedAt: String
        public let summary: String?
    }

    /// 读某录音已存的摘要正文 + 所用模板 id（录音库摘要页展示用）。
    public func recordingSummaryInfo(id: String) -> (summary: String?, template: String?) {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "select summary, summary_template from recordings where id=?", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, id)
        guard sqlite3_step(st) == SQLITE_ROW else { return (nil, nil) }
        let summary = sqlite3_column_text(st, 0).map { String(cString: $0) }
        let tmpl = sqlite3_column_text(st, 1).map { String(cString: $0) }
        return (summary, tmpl)
    }

    /// 列出某日期范围内的录音（按时间正序），供"汇总昨天/上周"等 digest。
    public func recordingsInRange(_ range: DateRange) -> [RecordingRow] {
        // recorded_at 是 ISO8601；用其前 10 位（yyyy-MM-dd）比较。
        let sql = """
        select id, title, recorded_at, summary from recordings
        where substr(recorded_at,1,10) between ? and ? order by recorded_at
        """
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, range.from); bindText(st, 2, range.to)
        var out: [RecordingRow] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let summary = sqlite3_column_text(st, 3).map { String(cString: $0) }
            out.append(RecordingRow(
                id: String(cString: sqlite3_column_text(st, 0)),
                title: String(cString: sqlite3_column_text(st, 1)),
                recordedAt: String(cString: sqlite3_column_text(st, 2)),
                summary: summary))
        }
        return out
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
