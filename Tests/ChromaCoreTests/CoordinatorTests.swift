import XCTest
@testable import ChromaCore
final class CoordinatorTests: XCTestCase {
    func testLiveBrightnessIsScaledOnlyInRGB() async throws {
        let capture=PacketCapture()
        let usb=RazerUSBActor{request in capture.add(request);var r=request;r[0]=2;return r}
        var p=Preset(name:"Half");p.mode = .pulse;p.brightness=0.5
        try await usb.apply(p)
        XCTAssertEqual(capture.packets.first?[10],255)
    }
    func testStoppedGenerationCannotWriteAndFailureBacksOff() {
        var state=StreamState(rate:25)
        let generation=state.generation
        state.stop()
        XCTAssertFalse(state.accepts(generation))
        state.start(rate:25)
        for _ in 0..<3 { state.failed() }
        XCTAssertEqual(state.rate,20)
    }
    func testUnavailableInputDoesNotFabricateColour() {
        var p=Preset(name:"battery");p.mode = .battery
        XCTAssertNil(p.color(time:0,input:nil))
    }
    func testActorSerializesConcurrentTransactions() async throws {
        let tracker=Tracker()
        let usb=RazerUSBActor { request in
            tracker.begin();Thread.sleep(forTimeInterval:0.005);tracker.end()
            var response=request;response[0]=2;return response
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await usb.exchange(Commands.off()) } }
            try await group.waitForAll()
        }
        XCTAssertEqual(tracker.maximum,1)
    }
}
private final class PacketCapture: @unchecked Sendable {let lock=NSLock();var packets:[[UInt8]]=[];func add(_ p:[UInt8]){lock.lock();packets.append(p);lock.unlock()}}
private final class Tracker: @unchecked Sendable {
    let lock=NSLock();var active=0;var maximum=0
    func begin(){lock.lock();active += 1;maximum=max(maximum,active);lock.unlock()}
    func end(){lock.lock();active -= 1;lock.unlock()}
}
