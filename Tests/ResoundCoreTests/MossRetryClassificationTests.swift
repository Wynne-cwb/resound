import XCTest
@testable import ResoundCore

/// MOSS 重试分类（`MossTranscriber.isTransient`）：哪些错误值得重提交、哪些重试只是白等。
/// 分类错了代价不对称——该重试的不重试丢任务，不该重试的重试白烧 GPU 额度/白等几小时，
/// 所以把判定表固定在单测里。
final class MossRetryClassificationTests: XCTestCase {

    // 瞬时：重试大概率就过
    func testServerErrorsAreTransient() {
        XCTAssertTrue(MossTranscriber.isTransient(MossError.http(500, "container preempted")))
        XCTAssertTrue(MossTranscriber.isTransient(MossError.http(502, "bad gateway")))
        XCTAssertTrue(MossTranscriber.isTransient(MossError.http(503, "overloaded")))
    }

    func testBadResponseIsTransient() {
        XCTAssertTrue(MossTranscriber.isTransient(MossError.badResponse("submit 响应缺 call_id")))
    }

    func testUnknownNonConnectivityErrorIsTransient() {
        // 非 MossError 的未知错误（URLSession 抖动等）：只要不是连接类就值得再试一次
        struct Oops: Error {}
        XCTAssertTrue(MossTranscriber.isTransient(Oops()))
        XCTAssertTrue(MossTranscriber.isTransient(URLError(.badServerResponse)))
    }

    // 必然复现：重试只是白等 / 白烧额度
    func testClientErrorsAreNotTransient() {
        XCTAssertFalse(MossTranscriber.isTransient(MossError.http(401, "unauthorized")))
        XCTAssertFalse(MossTranscriber.isTransient(MossError.http(403, "forbidden")))
        XCTAssertFalse(MossTranscriber.isTransient(MossError.http(404, "not found")))
    }

    func testBadConfigIsNotTransient() {
        XCTAssertFalse(MossTranscriber.isTransient(MossError.badConfig("endpoint 未配置")))
    }

    func testTimeoutIsNotTransient() {
        // 单次已等满 deadline（缺省 60 分钟），再重试 3 次最坏 4 小时才报错
        XCTAssertFalse(MossTranscriber.isTransient(MossError.timeout(3600)))
    }

    func testEmptyIsNotTransient() {
        // 整段静音是正常结果不是故障，重提交只会再算一遍 GPU 还是空
        XCTAssertFalse(MossTranscriber.isTransient(MossError.empty))
    }

    func testConnectivityErrorsAreNotTransient() {
        // 连接类错误由 ConnectivityPatience 无限等网络，不走计次重试
        XCTAssertFalse(MossTranscriber.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertFalse(MossTranscriber.isTransient(URLError(.networkConnectionLost)))
        XCTAssertFalse(MossTranscriber.isTransient(URLError(.timedOut)))
    }
}
