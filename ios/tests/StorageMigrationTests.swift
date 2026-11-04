/**
 * 存储迁移的判据：旧数据能升级，而不是删了重来。
 *
 * 最要紧的是第一条 —— 它用的样本是**真实存在过的格式**（建封套之前的那份裸 JSON），
 * 不是为测试编出来的。编出来的样本只能证明「迁移函数能跑」，证明不了「老用户的键读得动」。
 */
import XCTest

@testable import DshMobile

final class StorageMigrationTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "dsh.migration.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - MeshConfig 的真实迁移

    /// 建封套之前，键里存的就是这一份：两个字段的裸 JSON，没有 `v`。
    /// 这条判据守的是「升级上来的用户不用重填地址」。
    private static let legacyBareJSON = #"""
    {"controlURLString":"https://hs.example:8443","gatewayURLString":"http://100.64.0.2:3081"}
    """#

    func testABarePayloadFromBeforeTheEnvelopeStillReads() {
        defaults.set(Self.legacyBareJSON, forKey: "mesh.config.v1")

        guard case .ok(let config) = MeshConfig.read(defaults) else {
            return XCTFail("老格式读不出来 —— 升级会把一次掉线变成一次重配")
        }
        XCTAssertEqual(config.controlURLString, "https://hs.example:8443")
        XCTAssertEqual(config.gatewayURLString, "http://100.64.0.2:3081")
    }

    func testWhatWeWriteNowIsVersioned() {
        let config = MeshConfig(controlURLString: "https://hs:8443", gatewayURLString: "http://100.64.0.3:3081")
        config.save(defaults)

        let raw = defaults.string(forKey: "mesh.config")
        XCTAssertNotNil(raw, "写出去要落在新键上")
        let stored = VersionedPayload.read(raw ?? "")
        XCTAssertEqual(stored?.version, MeshConfig.payloadVersion,
                       "写出去的那份必须带着当前版本号 —— 否则下一次没人知道它是哪一版")
    }

    func testSavingClearsTheLegacyKey() {
        // 不清的话，「清空配置」之后旧键会再次生效：用户以为清掉了，下次启动又回来了。
        defaults.set(Self.legacyBareJSON, forKey: "mesh.config.v1")
        MeshConfig.unconfigured.save(defaults)

        XCTAssertNil(defaults.string(forKey: "mesh.config.v1"), "旧键必须被清掉")
        XCTAssertNotNil(defaults.string(forKey: "mesh.config"))
    }

    func testAnUnknownVersionIsDamagedNotGuessed() {
        // 版本比当前新：按当前形状硬读会读出一个缺字段的配置 —— 那比读不出来更坏，
        // 因为它看起来是好的。
        let future = #"{"v":99,"payload":{"controlURLString":"https://x","gatewayURLString":"http://y"}}"#
        defaults.set(future, forKey: "mesh.config")

        XCTAssertEqual(MeshConfig.read(defaults), .damaged)
    }

    func testSomethingThatIsNotAJSONObjectIsDamaged() {
        defaults.set("not json at all", forKey: "mesh.config")
        XCTAssertEqual(MeshConfig.read(defaults), .damaged)
    }

    func testNoKeyAtAllIsMissing() {
        XCTAssertEqual(MeshConfig.read(defaults), .missing)
    }

    // MARK: - 迁移链本身

    func testAMissingStepReturnsNothingInsteadOfGuessing() {
        // 链上缺一步就是迁不动。猜出来的配置会让节点连错地方 —— 宁可报 damaged。
        let stored = VersionedPayload.Stored(version: 1, payload: Data(#"{"a":1}"#.utf8))
        XCTAssertNil(VersionedPayload.migrate(stored, to: 3, steps: [1: { $0 }]))
    }

    func testAStepThatFailsStopsTheChain() {
        let stored = VersionedPayload.Stored(version: 0, payload: Data(#"{"a":1}"#.utf8))
        XCTAssertNil(VersionedPayload.migrate(stored, to: 2, steps: [0: { _ in nil }, 1: { $0 }]))
    }

    func testMigrationIsIdempotent() {
        // 同一份旧数据迁多少次结果都一样 —— 读时迁移不写回，所以这条必须成立，
        // 否则「读一次迁一次」会越迁越偏。
        let stored = VersionedPayload.Stored(version: 0, payload: Data(Self.legacyBareJSON.utf8))
        let first = VersionedPayload.migrate(stored, to: 1, steps: MeshConfig.migrations)
        let second = VersionedPayload.migrate(stored, to: 1, steps: MeshConfig.migrations)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func testBareJSONReadsAsVersionZero() {
        let stored = VersionedPayload.read(Self.legacyBareJSON)
        XCTAssertEqual(stored?.version, 0, "没有 v 的裸 JSON 必须认成版本 0，不是「坏了」")
    }

    // MARK: - 那条被点名「靠人记住」的隐式迁移

    /// `ControlPlaneRecord` 的「没记录过 = 匹配」是一次**有意的**隐式迁移：老版本升上来时
    /// 状态目录里躺着有效身份，不该因为「我们刚开始记」就重注册一遍 —— 那会把一次升级
    /// 变成一次掉线。
    ///
    /// 这条判据守的就是这个行为。它是隐式的，所以特别容易被下一个人「顺手改成 false」。
    func testNoRecordCountsAsAMatch() {
        let url = URL(string: "https://hs.example:8443")
        XCTAssertTrue(ControlPlaneRecord.matches(url, defaults: defaults),
                      "没记录过必须算匹配 —— 否则升级会让所有老用户掉线一次")
    }

    func testARecordedDifferentControlPlaneDoesNotMatch() {
        ControlPlaneRecord.save(URL(string: "https://old.example:8443"), defaults: defaults)
        XCTAssertFalse(ControlPlaneRecord.matches(URL(string: "https://new.example:8443"), defaults: defaults))
    }

    func testATrailingSlashIsNotADifferentControlPlane() {
        ControlPlaneRecord.save(URL(string: "https://hs.example:8443"), defaults: defaults)
        XCTAssertTrue(ControlPlaneRecord.matches(URL(string: "https://hs.example:8443/"), defaults: defaults))
    }
}
