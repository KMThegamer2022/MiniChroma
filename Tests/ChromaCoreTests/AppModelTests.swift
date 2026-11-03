import XCTest
import ChromaCore
@testable import MiniChroma
final class AppModelTests:XCTestCase {
    @MainActor func testFirmwareSelectionWinsOverInFlightLiveFrame() async throws {
        let usb=RazerUSBActor{request in
            if request[7] == 3 {Thread.sleep(forTimeInterval:0.1)}
            var response=request;response[0]=2;return response
        }
        let model=AppModel(usb:usb,monitor:false)
        model.preset.mode = .rainbow;model.apply()
        try await Task.sleep(for:.milliseconds(30))
        model.preset.mode = .off;model.apply()
        try await Task.sleep(for:.milliseconds(250))
        XCTAssertEqual(model.status,"On-mouse · Off")
        XCTAssertTrue(model.active)
        model.stop()
    }
    @MainActor func testApplyCannotInterruptDiagnostics() {
        let model=AppModel(monitor:false)
        model.testing=true;model.status="Testing";model.apply()
        XCTAssertEqual(model.status,"Testing")
        XCTAssertFalse(model.active)
    }
}
