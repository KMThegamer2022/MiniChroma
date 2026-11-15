import Foundation
import USBBridge

/// A Razer USB device this app can drive. The transaction ID is the byte the
/// device expects at offset 1 of every report: the DeathAdder uses 0x3F, the
/// Ornata V3 X keyboard uses 0x1F (verified by a read-only firmware query).
public struct DeviceProfile: Sendable, Equatable {
    public let name: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let transaction: UInt8
    /// Keyboards use the extended matrix commands (class 0x0F, LED 0x05); the mouse uses its own layout.
    public let isKeyboard: Bool
    public init(name: String, vendorID: UInt16, productID: UInt16, transaction: UInt8, isKeyboard: Bool = false) {
        self.name=name; self.vendorID=vendorID; self.productID=productID; self.transaction=transaction; self.isKeyboard=isKeyboard
    }
    public static let mouse = DeviceProfile(name: "DeathAdder V2 Mini", vendorID: 0x1532, productID: 0x008C, transaction: 0x3F)
    public static let keyboard = DeviceProfile(name: "Ornata V3 X", vendorID: 0x1532, productID: 0x02A2, transaction: 0x1F, isKeyboard: true)
}

/// Keyboard lighting commands, following OpenRazer's extended matrix layout for this keyboard family.
/// Arguments: variable storage 0x01, backlight LED 0x05.
public enum KeyboardCommands {
    public static func brightness(_ value: UInt8) -> RazerReport { RazerReport(commandClass: 15, command: 4, arguments: [1,5,value]) }
    public static func getBrightness() -> RazerReport { RazerReport(commandClass: 15, command: 0x84, arguments: [1,5,0]) }
    public static func staticColor(_ color: RGB) -> RazerReport { RazerReport(commandClass: 15, command: 2, arguments: [1,5,1,0,0,1]+color.bytes, size: 9) }
    public static func off() -> RazerReport { RazerReport(commandClass: 15, command: 2, arguments: [1,5,0,0,0,0], size: 6) }
    public static func spectrum() -> RazerReport { RazerReport(commandClass: 15, command: 2, arguments: [1,5,3,0,0,0], size: 6) }
}

public actor RazerUSBActor {
    private var handle: OpaquePointer?
    private let mock: (@Sendable ([UInt8]) throws -> [UInt8])?
    public let profile: DeviceProfile
    public init(profile: DeviceProfile = .mouse, exchange: (@Sendable ([UInt8]) throws -> [UInt8])? = nil) {
        self.profile=profile; mock=exchange
    }
    public func close() { if let handle { mc_close(handle) }; handle=nil }
    public func exchange(_ command: RazerReport) throws -> [UInt8] {
        // The keyboard can report "busy" while it settles after a write; retry briefly before failing.
        guard profile.isKeyboard else { return try exchangeOnce(command) }
        var attempt = 0
        while true {
            do { return try exchangeOnce(command) }
            catch let error as ProtocolError where error.message.contains("busy") && attempt < 4 {
                attempt += 1
                Thread.sleep(forTimeInterval: 0.08)
            }
        }
    }
    private func exchangeOnce(_ command: RazerReport) throws -> [UInt8] {
        // The checksum covers bytes 2...87 only, so changing byte 1 keeps the report valid.
        let request = command.withTransaction(profile.transaction)
        let reply: [UInt8]
        if let mock { reply=try mock(request.bytes) }
        else {
            if handle == nil {
                var error: Int32=0
                handle=mc_open(profile.vendorID,profile.productID,&error)
                guard handle != nil else { throw ProtocolError(String(format:"Cannot open %@ (0x%08x)",profile.name,error)) }
            }
            var data=[UInt8](repeating:0,count:90)
            let result=request.bytes.withUnsafeBufferPointer { req in data.withUnsafeMutableBufferPointer { response in mc_exchange(handle,req.baseAddress,response.baseAddress) } }
            guard result == 0 else { close(); throw ProtocolError(String(format:"USB transfer failed (0x%08x)",result)) }
            reply=data
        }
        try request.validate(reply)
        return reply
    }
    /// Shows one raw colour frame. Both devices take the same frame command once custom mode is on.
    public func show(_ color: RGB) throws {
        _ = try exchange(Commands.frame(color))
    }
    public func apply(_ preset: Preset) throws {
        if profile.isKeyboard { try applyKeyboard(preset); return }
        _ = try exchange(Commands.brightness(preset.mode.live ? 255 : UInt8((preset.brightness*255).rounded())))
        _ = try exchange(preset.mode.live ? Commands.custom() : Commands.firmware(preset.mode,primary:preset.primary,secondary:preset.secondary,speed:preset.reactiveSpeed))
    }
    private func applyKeyboard(_ preset: Preset) throws {
        // Live modes stream raw frames through show(), so the keyboard's brightness stays at full scale.
        _ = try exchange(KeyboardCommands.brightness(preset.mode.live ? 255 : UInt8((preset.brightness*255).rounded())))
        if preset.mode.live { _ = try exchange(Commands.custom()); return }
        switch preset.mode {
        case .off: _ = try exchange(KeyboardCommands.off())
        case .staticColor: _ = try exchange(KeyboardCommands.staticColor(preset.primary))
        case .spectrum: _ = try exchange(KeyboardCommands.spectrum())
        default:
            // Never leave the previous colour lit when an effect is unsupported.
            _ = try? exchange(KeyboardCommands.off())
            throw ProtocolError("\(preset.mode.title) is not available on the \(profile.name) yet; keyboard turned off")
        }
    }
}
