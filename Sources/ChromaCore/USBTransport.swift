import Foundation
import USBBridge

public actor RazerUSBActor {
    private var handle: OpaquePointer?
    private let mock: (@Sendable ([UInt8]) throws -> [UInt8])?
    public init(exchange: (@Sendable ([UInt8]) throws -> [UInt8])? = nil) { mock=exchange }
    public func close() { if let handle { mc_close(handle) }; handle=nil }
    public func exchange(_ command: RazerReport) throws -> [UInt8] {
        let reply: [UInt8]
        if let mock { reply=try mock(command.bytes) }
        else {
            if handle == nil { var error: Int32=0; handle=mc_open(&error); guard handle != nil else { throw ProtocolError(String(format:"Cannot open DeathAdder V2 Mini (0x%08x)",error)) } }
            var data=[UInt8](repeating:0,count:90)
            let result=command.bytes.withUnsafeBufferPointer { request in data.withUnsafeMutableBufferPointer { response in mc_exchange(handle,request.baseAddress,response.baseAddress) } }
            guard result == 0 else { close(); throw ProtocolError(String(format:"USB transfer failed (0x%08x)",result)) }
            reply=data
        }
        try command.validate(reply)
        return reply
    }
    public func apply(_ preset: Preset) throws {
        _ = try exchange(Commands.brightness(preset.mode.live ? 255 : UInt8((preset.brightness*255).rounded())))
        _ = try exchange(preset.mode.live ? Commands.custom() : Commands.firmware(preset.mode,primary:preset.primary,secondary:preset.secondary,speed:preset.reactiveSpeed))
    }
}
