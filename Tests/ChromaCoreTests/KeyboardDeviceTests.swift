import XCTest
@testable import ChromaCore

final class KeyboardDeviceTests: XCTestCase {
    private final class Box: @unchecked Sendable { var requests: [[UInt8]] = [] }

    func testKeyboardReportsUseItsTransactionIDAndValidChecksum() async throws {
        let box = Box()
        let usb = RazerUSBActor(profile: .keyboard) { request in
            box.requests.append(request)
            var reply = request; reply[0] = 2; return reply
        }
        _ = try await usb.exchange(Commands.firmwareVersion())
        let sent = try XCTUnwrap(box.requests.first)
        XCTAssertEqual(sent[1], 0x1F)
        XCTAssertEqual(sent[88], sent[2...87].reduce(0, ^))
    }

    func testMouseReportsKeepTheirTransactionID() async throws {
        let box = Box()
        let usb = RazerUSBActor(profile: .mouse) { request in
            box.requests.append(request)
            var reply = request; reply[0] = 2; return reply
        }
        _ = try await usb.exchange(Commands.brightness(128))
        XCTAssertEqual(try XCTUnwrap(box.requests.first)[1], 0x3F)
    }

    func testTransactionChangeKeepsCommandBody() {
        let original = Commands.frame(RGB(1, 0, 0))
        let changed = original.withTransaction(0x1F)
        XCTAssertEqual(Array(changed.bytes[2...]), Array(original.bytes[2...]))
        XCTAssertEqual(changed.bytes[1], 0x1F)
    }

    func testProfilesHaveRazerIDsAndDistinctTransactions() {
        XCTAssertEqual(DeviceProfile.mouse.productID, 0x008C)
        XCTAssertEqual(DeviceProfile.keyboard.productID, 0x02A2)
        XCTAssertEqual(DeviceProfile.keyboard.vendorID, 0x1532)
        XCTAssertNotEqual(DeviceProfile.mouse.transaction, DeviceProfile.keyboard.transaction)
    }
}
