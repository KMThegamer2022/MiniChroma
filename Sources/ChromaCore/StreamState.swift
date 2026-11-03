import Foundation
public struct StreamState: Sendable {
    public private(set) var generation=UUID()
    public private(set) var running=false
    public private(set) var rate: Double
    private var failures=0
    public init(rate: Double) { self.rate=rate }
    public mutating func start(rate:Double) { generation=UUID();running=true;self.rate=min(30,max(1,rate));failures=0 }
    public mutating func stop() { generation=UUID();running=false }
    public func accepts(_ token:UUID)->Bool { running && generation == token }
    public mutating func failed() { failures += 1; if failures >= 3 { rate=[25.0,20,15,10,5,1].first(where:{$0<rate}) ?? 1;failures=0 } }
    public mutating func succeeded() { failures=0 }
}
public struct PresetFile: Codable {
    public var version=1
    public var presets:[Preset]
    public init(presets:[Preset]) { self.presets=presets }
}
public enum PresetRepository {
    public static var directory: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("MiniChroma",isDirectory:true) }
    public static func load(from directory:URL=directory) throws -> [Preset] {
        let url=directory.appendingPathComponent("presets.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return [] }
        let file=try JSONDecoder().decode(PresetFile.self,from:Data(contentsOf:url))
        guard file.version == 1 else { throw ProtocolError("Unsupported preset file version") }
        return file.presets.map { var p=$0;p.normalize();return p }
    }
    public static func save(_ presets:[Preset],to directory:URL=directory) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(PresetFile(presets:presets)).write(to:directory.appendingPathComponent("presets.json"),options:.atomic)
    }
}
