import XCTest
@testable import PVLibrary

final class GameMetadataLookupThrottleTests: XCTestCase {
    func testLimitsConcurrentMetadataLookups() async {
        let throttle = GameMetadataLookupThrottle(maxConcurrentLookups: 2)
        let counter = ConcurrentLookupCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await throttle.withPermit {
                        await counter.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        await counter.leave()
                    }
                }
            }
        }

        let maximum = await counter.maximum
        XCTAssertEqual(maximum, 2)
    }
}

private actor ConcurrentLookupCounter {
    private(set) var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() {
        active -= 1
    }
}
