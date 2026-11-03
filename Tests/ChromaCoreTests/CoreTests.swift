import XCTest
@testable import ChromaCore
final class CoreTests: XCTestCase {
    func testOffAndBrightnessReadbackAddressSameVolatileLogo() {
        XCTAssertEqual(Array(Commands.off().bytes[5...13]),[6,15,2,0,4,0,0,0,0])
        XCTAssertEqual(Array(Commands.getBrightness().bytes[5...10]),[3,15,132,0,4,0])
    }
    func testStaticPacketUsesVolatileLogoAndValidChecksum() throws {
        let p = Commands.firmware(.staticColor, primary: RGB(1,0,0)).bytes
        XCTAssertEqual(p.count, 90)
        XCTAssertEqual(Array(p[0...16]), [0,63,0,0,0,9,15,2,0,4,1,0,0,1,255,0,0])
        XCTAssertEqual(p[88], 0xFF ^ 9 ^ 15 ^ 2 ^ 4 ^ 1 ^ 1)
    }
    func testCustomFrameUsesOnePixelAndFixedPayloadSize() {
        let p = Commands.frame(RGB(0,1,0)).bytes
        XCTAssertEqual(Array(p[5...15]), [71,15,3,0,0,0,0,0,0,255,0])
    }
    func testReplyRejectsCorruptionAndWrongCommandAndBusy() throws {
        let request = Commands.off()
        var reply = request.bytes; reply[0] = 2
        XCTAssertNoThrow(try request.validate(reply))
        reply[14] = 1
        XCTAssertThrowsError(try request.validate(reply))
        reply = request.bytes; reply[0] = 1
        XCTAssertThrowsError(try request.validate(reply))
        reply = request.bytes; reply[0] = 2; reply[1] = 31
        XCTAssertThrowsError(try request.validate(reply))
    }
    func testVolumeStopsAndSmoothingAreRateIndependent() {
        XCTAssertEqual(RGB.volume(0), RGB(0,1,0))
        XCTAssertEqual(RGB.volume(0.6), RGB(1,1,0))
        XCTAssertEqual(RGB.volume(1), RGB(1,0,0))
        let once = RGB.black.smoothed(to: .white, dt: 1, tau: 0.5)
        var many = RGB.black
        for _ in 0..<25 { many = many.smoothed(to: .white, dt: 0.04, tau: 0.5) }
        XCTAssertEqual(once.r, many.r, accuracy: 0.00001)
    }
    func testSettingsClampInvalidValuesAndPresetsRoundTrip() throws {
        var p = Preset(name: "Test"); p.rate = 500; p.period = 0; p.smoothing = -1
        p.normalize()
        XCTAssertEqual(p.rate, 30); XCTAssertEqual(p.period, 0.2); XCTAssertEqual(p.smoothing, 0)
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Preset.self, from: data), p)
    }
}
