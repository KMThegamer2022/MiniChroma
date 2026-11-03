import XCTest
@testable import ChromaCore
final class PersistenceTests:XCTestCase {
    func testAtomicPresetStorageAndUnsupportedVersion() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("MiniChroma-tests-\(UUID())")
        defer{try? FileManager.default.removeItem(at:directory)}
        XCTAssertEqual(try PresetRepository.load(from:directory),[])
        var p=Preset(name:"Saved rainbow");p.mode = .rainbow;p.period=7
        try PresetRepository.save([p],to:directory)
        XCTAssertEqual(try PresetRepository.load(from:directory),[p])
        try Data("{\"version\":2,\"presets\":[]}".utf8).write(to:directory.appendingPathComponent("presets.json"))
        XCTAssertThrowsError(try PresetRepository.load(from:directory))
    }
}
