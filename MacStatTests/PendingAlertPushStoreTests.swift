import XCTest
@testable import MacStatKit

final class PendingAlertPushStoreTests: XCTestCase {

    private func makeStore() -> PendingAlertPushStore {
        // Throwaway suite per test so state never leaks between tests or
        // into the real app's persisted queue — same convention
        // `PowerControlServiceTests` uses for `PowerControlService`.
        PendingAlertPushStore(defaults: UserDefaults(suiteName: "test.pendingAlertPush.\(UUID().uuidString)")!)
    }

    private func push(_ name: String) -> AlertPush {
        AlertPush(deviceID: "device-1", ruleName: name, title: name, body: "body", firedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testEnqueuePersistsAcrossReads() {
        let store = makeStore()
        store.enqueue(push("Low battery"))
        XCTAssertEqual(store.all().map(\.ruleName), ["Low battery"])
    }

    func testEnqueueAppends() {
        let store = makeStore()
        store.enqueue(push("Low battery"))
        store.enqueue(push("Critical battery"))
        XCTAssertEqual(store.all().map(\.ruleName), ["Low battery", "Critical battery"])
    }

    func testDrainReturnsAndEmptiesQueue() {
        let store = makeStore()
        store.enqueue(push("Low battery"))
        store.enqueue(push("Critical battery"))

        let drained = store.drain()
        XCTAssertEqual(drained.map(\.ruleName), ["Low battery", "Critical battery"])
        XCTAssertTrue(store.all().isEmpty)
    }

    func testEmptyStoreReturnsEmptyArray() {
        XCTAssertTrue(makeStore().all().isEmpty)
    }

    func testCapacityDropsOldestEntries() {
        let store = makeStore()
        for index in 0..<210 {
            store.enqueue(push("rule-\(index)"))
        }
        let all = store.all()
        XCTAssertEqual(all.count, 200)
        XCTAssertEqual(all.first?.ruleName, "rule-10")
        XCTAssertEqual(all.last?.ruleName, "rule-209")
    }
}
