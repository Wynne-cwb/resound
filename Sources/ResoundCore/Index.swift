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
    public let sourceKind: String   // "recording" | "document"
    public let docId: String?       // 文档来源时填
    public let docTitle: String?    // 文档标题（镜像自 documents 表；引用展示用）

    public init(rowid: Int64, text: String, recordingId: String, start: Double, end: Double,
                score: Double, personId: String?, recordingDate: String?,
                sourceKind: String = "recording", docId: String? = nil, docTitle: String? = nil) {
        self.rowid = rowid; self.text = text; self.recordingId = recordingId
        self.start = start; self.end = end; self.score = score
        self.personId = personId; self.recordingDate = recordingDate
        self.sourceKind = sourceKind; self.docId = docId; self.docTitle = docTitle
    }

    public var isDocument: Bool { sourceKind == "document" }
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
        create table if not exists embedding_cache(hash text primary key, vec text, model text);
        create table if not exists speaker_refs(name text primary key, count integer, vec text);
        create table if not exists documents(id text primary key, title text, imported_at text);
        create table if not exists doc_links(doc_id text, recording_id text);
        """)
        // 增量迁移（旧库 create-if-not-exists 不会加新列）。
        addColumnIfMissing(table: "chunks", column: "recording_date", decl: "text")
        addColumnIfMissing(table: "chunks", column: "source_kind", decl: "text default 'recording'")
        addColumnIfMissing(table: "chunks", column: "doc_id", decl: "text")
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

    // MARK: embedding 缓存（按 hash(model+入向量文本) 缓存原始向量，避免重建索引/改错字重复付费）
    // 存的是 embedDocuments 返回的**原始**向量；归一化由 insertChunk 统一做。

    public func cachedEmbedding(hash: String) -> [Float]? {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "select vec from embedding_cache where hash=?", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, hash)
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        return parseVectorJSON(String(cString: c))
    }

    public func setCachedEmbedding(hash: String, vec: [Float], model: String) throws {
        let sql = """
        insert into embedding_cache(hash,vec,model) values(?,?,?)
        on conflict(hash) do update set vec=excluded.vec, model=excluded.model
        """
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, hash); bindText(st, 2, vectorJSON(vec)); bindText(st, 3, model)
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

    // MARK: 文档（来源类型 document）

    public func upsertDocument(id: String, title: String, importedAt: String) throws {
        let sql = """
        insert into documents(id,title,imported_at) values(?,?,?)
        on conflict(id) do update set title=excluded.title, imported_at=excluded.imported_at
        """
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, id); bindText(st, 2, title); bindText(st, 3, importedAt)
        guard sqlite3_step(st) == SQLITE_DONE else { throw IndexError.sql(lastErr()) }
    }

    /// 删除某文档已有的 chunks（重建幂等）。
    public func deleteChunks(docId: String) throws {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "select id from chunks where doc_id=?", -1, &st, nil)
        bindText(st, 1, docId)
        var ids: [Int64] = []
        while sqlite3_step(st) == SQLITE_ROW { ids.append(sqlite3_column_int64(st, 0)) }
        sqlite3_finalize(st)
        for rid in ids {
            try exec("delete from chunks_fts where rowid=\(rid)")
            try exec("delete from chunks_vec where rowid=\(rid)")
        }
        try exec("delete from chunks where doc_id='\(docId.replacingOccurrences(of: "'", with: "''"))'")
    }

    /// 重写某文档的关联录音镜像（事实源是 document.yaml；这里只做快速反查镜像）。
    public func setDocLinks(docId: String, recordingIds: [String]) throws {
        var del: OpaquePointer?
        sqlite3_prepare_v2(db, "delete from doc_links where doc_id=?", -1, &del, nil)
        bindText(del, 1, docId)
        _ = sqlite3_step(del); sqlite3_finalize(del)
        for rid in recordingIds {
            var st: OpaquePointer?
            sqlite3_prepare_v2(db, "insert into doc_links(doc_id,recording_id) values(?,?)", -1, &st, nil)
            bindText(st, 1, docId); bindText(st, 2, rid)
            _ = sqlite3_step(st); sqlite3_finalize(st)
        }
    }

    /// 某录音关联的文档（id+title），供录音详情「相关文档」反查。
    public func documentsLinked(toRecording recordingId: String) -> [(id: String, title: String)] {
        let sql = """
        select d.id, d.title from doc_links l join documents d on d.id = l.doc_id
        where l.recording_id=? order by d.imported_at desc
        """
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        defer { sqlite3_finalize(st) }
        bindText(st, 1, recordingId)
        var out: [(String, String)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((String(cString: sqlite3_column_text(st, 0)), String(cString: sqlite3_column_text(st, 1))))
        }
        return out
    }

    /// 删除某文档的全部索引数据（chunks + documents 行 + 关联镜像）。
    public func deleteDocument(id: String) throws {
        try deleteChunks(docId: id)
        let safe = id.replacingOccurrences(of: "'", with: "''")
        try exec("delete from doc_links where doc_id='\(safe)'")
        try exec("delete from documents where id='\(safe)'")
    }

    /// 清理「已不在 vault 里」的文档残留（chunks/documents/doc_links）。删文档若没走到索引清理、
    /// 或旧 id（如取回时标题变更导致 id 改变）留下的孤儿，会污染全局检索——启动时跑一次兜底。
    public func purgeOrphanDocuments(validDocIds: [String]) throws {
        let valid = Set(validDocIds)
        var ids = Set<String>()
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "select distinct doc_id from chunks where source_kind='document' and doc_id is not null", -1, &st, nil)
        while sqlite3_step(st) == SQLITE_ROW { if let c = sqlite3_column_text(st, 0) { ids.insert(String(cString: c)) } }
        sqlite3_finalize(st)
        var st2: OpaquePointer?
        sqlite3_prepare_v2(db, "select id from documents", -1, &st2, nil)
        while sqlite3_step(st2) == SQLITE_ROW { if let c = sqlite3_column_text(st2, 0) { ids.insert(String(cString: c)) } }
        sqlite3_finalize(st2)
        for id in ids where !valid.contains(id) { try deleteDocument(id: id) }
    }

    public func insertChunk(recordingId: String?, idx: Int, text: String, context: String?,
                            start: Double, end: Double, personId: String?,
                            recordingDate: String?, embedding: [Float],
                            sourceKind: String = "recording", docId: String? = nil) throws {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db,
            "insert into chunks(recording_id,idx,text,context,start,end,person_id,recording_date,source_kind,doc_id) values(?,?,?,?,?,?,?,?,?,?)",
            -1, &st, nil)
        if let r = recordingId { bindText(st, 1, r) } else { sqlite3_bind_null(st, 1) }
        sqlite3_bind_int64(st, 2, Int64(idx))
        bindText(st, 3, text)
        if let c = context { bindText(st, 4, c) } else { sqlite3_bind_null(st, 4) }
        sqlite3_bind_double(st, 5, start); sqlite3_bind_double(st, 6, end)
        if let p = personId { bindText(st, 7, p) } else { sqlite3_bind_null(st, 7) }
        if let d = recordingDate { bindText(st, 8, d) } else { sqlite3_bind_null(st, 8) }
        bindText(st, 9, sourceKind)
        if let d = docId { bindText(st, 10, d) } else { sqlite3_bind_null(st, 10) }
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

    /// 修正某录音的日期（redate 用）：录音行的 recorded_at（ISO8601）+ 该录音全部 chunk 的 recording_date（yyyy-MM-dd）
    /// 一起更新，保证排序、digest（按 recorded_at）、qa 时间过滤（按 chunk recording_date）口径一致；不重嵌入。
    public func setRecordingDate(id: String, recordedAt: String, day: String) throws {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "update recordings set recorded_at=? where id=?", -1, &st, nil)
        if let st { bindText(st, 1, recordedAt); bindText(st, 2, id)
            guard sqlite3_step(st) == SQLITE_DONE else { sqlite3_finalize(st); throw IndexError.sql(lastErr()) } }
        sqlite3_finalize(st)
        var st2: OpaquePointer?
        sqlite3_prepare_v2(db, "update chunks set recording_date=? where recording_id=?", -1, &st2, nil)
        defer { sqlite3_finalize(st2) }
        if let st2 { bindText(st2, 1, day); bindText(st2, 2, id)
            guard sqlite3_step(st2) == SQLITE_DONE else { throw IndexError.sql(lastErr()) } }
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

    /// 过滤条件：可自由组合（都是 WHERE 的 AND）。speakers 命中 chunks.person_id；sourceKind 'recording'|'document'。
    public struct Filters {
        public var dateRange: DateRange?
        public var speakers: [String]?
        public var sourceKind: String?
        public var recordingId: String?
        public var docId: String?
        public init(dateRange: DateRange? = nil, speakers: [String]? = nil, sourceKind: String? = nil,
                    recordingId: String? = nil, docId: String? = nil) {
            self.dateRange = dateRange; self.speakers = speakers; self.sourceKind = sourceKind
            self.recordingId = recordingId; self.docId = docId
        }
        var isActive: Bool {
            dateRange != nil || (speakers?.isEmpty == false) || sourceKind != nil
                || recordingId != nil || docId != nil
        }
    }

    /// 把 Filters 拼成 SQL where 片段（c 为 chunks 别名）+ 绑定闭包，向量/FTS 共用，避免重复。
    private func filterClause(_ f: Filters) -> (sql: String, bind: (OpaquePointer?, inout Int32) -> Void) {
        var parts: [String] = []
        if f.dateRange != nil { parts.append("and c.recording_date between ? and ?") }
        if let sp = f.speakers, !sp.isEmpty {
            parts.append("and c.person_id in (\(Array(repeating: "?", count: sp.count).joined(separator: ",")))")
        }
        if f.sourceKind != nil { parts.append("and c.source_kind = ?") }
        if f.recordingId != nil { parts.append("and c.recording_id = ?") }
        if f.docId != nil { parts.append("and c.doc_id = ?") }
        let sql = parts.joined(separator: " ")
        let bind: (OpaquePointer?, inout Int32) -> Void = { st, bi in
            if let r = f.dateRange { bindText(st, bi, r.from); bi += 1; bindText(st, bi, r.to); bi += 1 }
            if let sp = f.speakers, !sp.isEmpty { for s in sp { bindText(st, bi, s); bi += 1 } }
            if let sk = f.sourceKind { bindText(st, bi, sk); bi += 1 }
            if let rid = f.recordingId { bindText(st, bi, rid); bi += 1 }
            if let did = f.docId { bindText(st, bi, did); bi += 1 }
        }
        return (sql, bind)
    }

    public func vectorSearch(_ queryVec: [Float], k: Int, filters: Filters = Filters()) throws -> [SearchHit] {
        // vec0 的 KNN 不支持前置过滤：带任何过滤时把候选放大，过滤后仍够用（个人 wiki 规模可接受）。
        let knnK = filters.isActive ? max(k, 4000) : k
        let (clause, bind) = filterClause(filters)
        let sql = """
        select c.id, c.text, c.recording_id, c.start, c.end, v.distance, c.person_id, c.recording_date,
               c.source_kind, c.doc_id, d.title
        from chunks_vec v join chunks c on c.id = v.rowid
        left join documents d on d.id = c.doc_id
        where v.embedding match ? and k = \(knnK) \(clause) order by v.distance limit \(k)
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw IndexError.sql(lastErr()) }
        defer { sqlite3_finalize(st) }
        var bi: Int32 = 1
        bindText(st, bi, vectorJSON(normalize(queryVec))); bi += 1
        bind(st, &bi)
        return readHits(st)
    }

    public func ftsSearch(_ query: String, k: Int, filters: Filters = Filters()) throws -> [SearchHit] {
        let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "") + "\""
        let (clause, bind) = filterClause(filters)
        let sql = """
        select c.id, c.text, c.recording_id, c.start, c.end, f.rank, c.person_id, c.recording_date,
               c.source_kind, c.doc_id, d.title
        from chunks_fts f join chunks c on c.id = f.rowid
        left join documents d on d.id = c.doc_id
        where chunks_fts match ? \(clause) order by f.rank limit \(k)
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw IndexError.sql(lastErr()) }
        defer { sqlite3_finalize(st) }
        var bi: Int32 = 1
        bindText(st, bi, phrase); bi += 1
        bind(st, &bi)
        return readHits(st)
    }

    private func readHits(_ st: OpaquePointer?) -> [SearchHit] {
        var hits: [SearchHit] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let person = sqlite3_column_text(st, 6).map { String(cString: $0) }
            let date = sqlite3_column_text(st, 7).map { String(cString: $0) }
            let kind = sqlite3_column_text(st, 8).map { String(cString: $0) } ?? "recording"
            let docId = sqlite3_column_text(st, 9).map { String(cString: $0) }
            let docTitle = sqlite3_column_text(st, 10).map { String(cString: $0) }
            let recId = sqlite3_column_text(st, 2).map { String(cString: $0) } ?? ""
            hits.append(SearchHit(
                rowid: sqlite3_column_int64(st, 0),
                text: String(cString: sqlite3_column_text(st, 1)),
                recordingId: recId,
                start: sqlite3_column_double(st, 3),
                end: sqlite3_column_double(st, 4),
                score: sqlite3_column_double(st, 5),
                personId: person,
                recordingDate: date,
                sourceKind: kind,
                docId: docId,
                docTitle: docTitle))
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

    /// 按 id 批量取录音行，保持传入 ids 的顺序（digest 主题子集用：先检索定子集再取摘要）。
    public func recordings(ids: [String]) -> [RecordingRow] {
        guard !ids.isEmpty else { return [] }
        let ph = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "select id, title, recorded_at, summary from recordings where id in (\(ph))"
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        defer { sqlite3_finalize(st) }
        for (i, id) in ids.enumerated() { bindText(st, Int32(i + 1), id) }
        var byId: [String: RecordingRow] = [:]
        while sqlite3_step(st) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(st, 0))
            byId[id] = RecordingRow(
                id: id, title: String(cString: sqlite3_column_text(st, 1)),
                recordedAt: String(cString: sqlite3_column_text(st, 2)),
                summary: sqlite3_column_text(st, 3).map { String(cString: $0) })
        }
        return ids.compactMap { byId[$0] }   // 保序 + 丢弃查不到的
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

/// 解析 vectorJSON 写出的 `[f,f,…]`。坏数据 → nil（当作缓存未命中，安全重嵌）。
func parseVectorJSON(_ s: String) -> [Float]? {
    let body = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] \n\t"))
    let parts = body.split(separator: ",")
    guard !parts.isEmpty else { return nil }
    var out = [Float](); out.reserveCapacity(parts.count)
    for p in parts {
        guard let f = Float(p.trimmingCharacters(in: .whitespaces)) else { return nil }
        out.append(f)
    }
    return out
}
