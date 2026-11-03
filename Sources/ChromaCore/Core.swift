import Foundation

public struct RGB: Codable, Equatable, Sendable {
    public var r: Double; public var g: Double; public var b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r=r; self.g=g; self.b=b }
    public static let black = RGB(0,0,0), white = RGB(1,1,1)
    public var bytes: [UInt8] { [r,g,b].map { UInt8((min(1,max(0,$0.isFinite ? $0 : 0))*255).rounded()) } }
    public func mixed(_ other: RGB, _ amount: Double) -> RGB { let t=min(1,max(0,amount)); return RGB(r+(other.r-r)*t,g+(other.g-g)*t,b+(other.b-b)*t) }
    public func smoothed(to target: RGB, dt: Double, tau: Double) -> RGB { mixed(target, tau <= 0 ? 1 : 1-exp(-max(0,dt)/tau)) }
    public static func volume(_ value: Double, midpoint: Double = 0.6) -> RGB { let m=min(0.99,max(0.01,midpoint)); return value <= m ? RGB(0,1,0).mixed(RGB(1,1,0),value/m) : RGB(1,1,0).mixed(RGB(1,0,0),(value-m)/(1-m)) }
    public static func hue(_ hue: Double) -> RGB {
        let h=(hue-floor(hue))*6, x=1-abs(h.truncatingRemainder(dividingBy: 2)-1)
        switch Int(h) { case 0:return RGB(1,x,0); case 1:return RGB(x,1,0); case 2:return RGB(0,1,x); case 3:return RGB(0,x,1); case 4:return RGB(x,0,1); default:return RGB(1,0,x) }
    }
}
public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, staticColor, spectrum, reactive, breathSingle, breathDual, breathRandom, volume, battery, temperature, audio, rainbow, pulse
    public var id: String { rawValue }
    public var live: Bool { [.volume,.battery,.temperature,.audio,.rainbow,.pulse].contains(self) }
    public var title: String { switch self { case .off:return "Off"; case .staticColor:return "Static"; case .spectrum:return "Spectrum"; case .reactive:return "Reactive"; case .breathSingle:return "Breathing · one colour"; case .breathDual:return "Breathing · two colours"; case .breathRandom:return "Breathing · random"; case .volume:return "System volume"; case .battery:return "Mac battery"; case .temperature:return "CPU temperature"; case .audio:return "Audio reactive"; case .rainbow:return "Custom rainbow"; case .pulse:return "Custom pulse" } }
}
public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var name: String; public var mode: Mode = .off
    public var primary = RGB(0,1,0), secondary = RGB(0,0,1)
    public var rate = 10.0, smoothing = 0.15, period = 4.0, midpoint = 0.6, brightness = 1.0, gain = 4.0, noiseGate = 0.01
    public var cool = 40.0, hot = 85.0; public var reactiveSpeed = 2
    public init(name: String) { self.name=name }
    public mutating func normalize() {
        rate = min(30,max(1,rate.isFinite ? rate : 10)); smoothing = min(5,max(0,smoothing.isFinite ? smoothing : 0.15)); period = min(120,max(0.2,period.isFinite ? period : 4)); midpoint=min(0.99,max(0.01,midpoint)); brightness=min(1,max(0,brightness)); gain=min(100,max(0,gain)); noiseGate=min(1,max(0,noiseGate)); cool=min(120,max(0,cool)); hot=min(130,max(cool+1,hot)); reactiveSpeed=min(4,max(1,reactiveSpeed))
    }
    public func color(time: Double, input: Double? = nil, muted: Bool = false) -> RGB? {
        let c: RGB
        switch mode {
        case .rainbow: c = .hue(time/max(0.2,period))
        case .pulse: c = primary.mixed(secondary, (1-cos(time/max(0.2,period)*2*Double.pi))/2)
        case .volume: guard let input else { return nil }; c = muted ? .black : .volume(input,midpoint: midpoint)
        case .battery: guard let input else { return nil }; c = .volume(1-input,midpoint: midpoint)
        case .temperature: guard let input else { return nil }; c = .volume((input-cool)/max(1,hot-cool),midpoint: midpoint)
        case .audio: guard let input else { return nil }; c = .black.mixed(primary, input < noiseGate ? 0 : min(1,input*gain))
        default: c = primary
        }
        return .black.mixed(c,brightness)
    }
}
public struct ProtocolError: Error, LocalizedError, Sendable { public let message: String; public var errorDescription: String? { message }; public init(_ message: String) { self.message=message } }
public struct RazerReport: Sendable {
    public let bytes: [UInt8]
    public init(commandClass: UInt8, command: UInt8, arguments: [UInt8], size: Int? = nil) {
        precondition(arguments.count <= 80)
        var b=[UInt8](repeating:0,count:90); b[1]=0x3f; b[5]=UInt8(size ?? arguments.count); b[6]=commandClass; b[7]=command
        b.replaceSubrange(8..<(8+arguments.count),with:arguments); b[88]=b[2...87].reduce(0,^); bytes=b
    }
    public func validate(_ reply: [UInt8]) throws {
        guard reply.count == 90 else { throw ProtocolError("Invalid reply length: \(reply.count)") }
        guard reply[88] == reply[2...87].reduce(0,^) else { throw ProtocolError("Reply checksum mismatch") }
        guard reply[1] == bytes[1], reply[2...4] == bytes[2...4], reply[6...7] == bytes[6...7], reply[5] <= 80 else { throw ProtocolError("Reply does not match command") }
        guard reply[0] == 2 else { throw ProtocolError("Device status \(reply[0]): \([1:"busy",3:"failed",4:"timeout",5:"unsupported"][Int(reply[0])] ?? "unknown")") }
    }
}
public enum Commands {
    public static func off() -> RazerReport { firmware(.off) }
    public static func firmware(_ mode: Mode, primary: RGB = RGB(0,1,0), secondary: RGB = RGB(0,0,1), speed: Int = 2) -> RazerReport {
        var args: [UInt8] = [0,4,0,0,0,0]
        switch mode {
        case .staticColor: args[2]=1; args[5]=1; args += primary.bytes
        case .spectrum: args[2]=3
        case .reactive: args[2]=5; args[4]=UInt8(min(4,max(1,speed))); args[5]=1; args += primary.bytes
        case .breathSingle: args[2]=2; args[3]=1; args[5]=1; args += primary.bytes
        case .breathDual: args[2]=2; args[3]=2; args[5]=2; args += primary.bytes+secondary.bytes
        case .breathRandom: args[2]=2
        default: break
        }
        return RazerReport(commandClass:15,command:2,arguments:args)
    }
    public static func custom() -> RazerReport { RazerReport(commandClass:15,command:2,arguments:[0,0,8,0,0,0,0,0,0,0,0,0]) }
    public static func frame(_ color: RGB) -> RazerReport { RazerReport(commandClass:15,command:3,arguments:[0,0,0,0,0]+color.bytes,size:71) }
    public static func firmwareVersion() -> RazerReport { RazerReport(commandClass:0,command:0x81,arguments:[0,0]) }
    public static func brightness(_ value: UInt8) -> RazerReport { RazerReport(commandClass:15,command:4,arguments:[0,4,value]) }
    public static func getBrightness() -> RazerReport { RazerReport(commandClass:15,command:0x84,arguments:[0,4,0]) }
}
