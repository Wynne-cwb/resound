import Foundation
import Compression

/// 最小 ZIP 读取器（零依赖）——docx/pptx 本质是 zip+XML，用它解出内部 XML 条目。
///
/// 只做"按名取条目内容"：解析 End of Central Directory → 中央目录 → 对需要的条目读 local header + 数据，
/// stored(method 0) 直接返回，deflate(method 8) 用 Apple **Compression** 框架解 raw deflate
/// （`COMPRESSION_ZLIB` 在 Apple 平台正好吃无 zlib 头的 raw deflate，这正是 zip 条目的存储方式）。
/// 不支持 zip64/加密/分卷——OOXML 文档一般用不到；遇到取不出就返回 nil，由上层兜底。
struct MiniZip {
    struct Entry {
        let name: String
        let method: Int
        let compSize: Int
        let uncompSize: Int
        let localOffset: Int
    }

    private let bytes: [UInt8]
    let entries: [Entry]

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url) else { return nil }
        self.init(data: d)
    }

    init?(data: Data) {
        let b = [UInt8](data)
        guard let eocd = MiniZip.findEOCD(b) else { return nil }
        let count = MiniZip.u16(b, eocd + 10)
        var off = MiniZip.u32(b, eocd + 16)
        var list: [Entry] = []
        for _ in 0..<count {
            guard off + 46 <= b.count, MiniZip.u32(b, off) == 0x02014b50 else { break }
            let method = MiniZip.u16(b, off + 10)
            let compSize = MiniZip.u32(b, off + 20)
            let uncompSize = MiniZip.u32(b, off + 24)
            let nameLen = MiniZip.u16(b, off + 28)
            let extraLen = MiniZip.u16(b, off + 30)
            let commentLen = MiniZip.u16(b, off + 32)
            let localOff = MiniZip.u32(b, off + 42)
            let nameEnd = off + 46 + nameLen
            let name = nameEnd <= b.count
                ? (String(bytes: b[(off + 46)..<nameEnd], encoding: .utf8) ?? "")
                : ""
            list.append(Entry(name: name, method: method, compSize: compSize,
                              uncompSize: uncompSize, localOffset: localOff))
            off += 46 + nameLen + extraLen + commentLen
        }
        self.bytes = b
        self.entries = list
    }

    func data(for name: String) -> Data? {
        guard let e = entries.first(where: { $0.name == name }) else { return nil }
        return data(for: e)
    }

    func data(for e: Entry) -> Data? {
        let lo = e.localOffset
        guard lo + 30 <= bytes.count, MiniZip.u32(bytes, lo) == 0x04034b50 else { return nil }
        // local header 的 nameLen/extraLen 可能与中央目录不同，必须以 local 为准
        let nameLen = MiniZip.u16(bytes, lo + 26)
        let extraLen = MiniZip.u16(bytes, lo + 28)
        let start = lo + 30 + nameLen + extraLen
        guard start >= 0, start + e.compSize <= bytes.count else { return nil }
        let comp = Data(bytes[start..<(start + e.compSize)])
        if e.method == 0 { return comp }                       // stored，未压缩
        if e.method == 8 { return MiniZip.inflate(comp, uncompSize: e.uncompSize) }
        return nil
    }

    /// raw deflate 解压（Compression 框架）。已知 uncompSize 时一把到位；未知则倍增重试。
    private static func inflate(_ data: Data, uncompSize: Int) -> Data? {
        var cap = uncompSize > 0 ? uncompSize + 16 : max(data.count * 20, 65_536)
        for _ in 0..<6 {
            var dst = Data(count: cap)
            let n = dst.withUnsafeMutableBytes { (dp: UnsafeMutableRawBufferPointer) -> Int in
                data.withUnsafeBytes { (sp: UnsafeRawBufferPointer) -> Int in
                    guard let dbase = dp.bindMemory(to: UInt8.self).baseAddress,
                          let sbase = sp.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dbase, cap, sbase, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 && n < cap { return dst.prefix(n) }   // n<cap → 写完且未截断
            if n == cap { cap *= 2; continue }             // 缓冲太小，倍增重试
            return nil
        }
        return nil
    }

    private static func findEOCD(_ b: [UInt8]) -> Int? {
        guard b.count >= 22 else { return nil }
        var i = b.count - 22
        let minI = max(0, b.count - 22 - 65_536)   // EOCD 注释最长 64KB
        while i >= minI {
            if u32(b, i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }

    // 越界安全的小端读取（畸形文件返回 0，靠上层 guard 兜底，不崩）
    static func u16(_ b: [UInt8], _ o: Int) -> Int {
        (o >= 0 && o + 1 < b.count) ? Int(b[o]) | (Int(b[o + 1]) << 8) : 0
    }
    static func u32(_ b: [UInt8], _ o: Int) -> Int {
        (o >= 0 && o + 3 < b.count)
            ? Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24)
            : 0
    }
}
