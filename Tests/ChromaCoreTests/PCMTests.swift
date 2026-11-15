import XCTest
@testable import ChromaCore
final class PCMTests:XCTestCase{
    func testFloat32And64EnergyAndMalformedFormats(){
        let floats:[Float]=[0.5,-0.5,0.5,-0.5]
        let e=floats.withUnsafeBytes{PCMLevel.energy($0,bits:32,isFloat:true,isBigEndian:false)}
        XCTAssertEqual(e?.sum,1);XCTAssertEqual(e?.count,4)
        let doubles:[Double]=[0.25,-0.25]
        let d=doubles.withUnsafeBytes{PCMLevel.energy($0,bits:64,isFloat:true,isBigEndian:false)}
        XCTAssertEqual(d?.sum,0.125);XCTAssertEqual(d?.count,2)
        XCTAssertNil(floats.withUnsafeBytes{PCMLevel.energy($0,bits:24,isFloat:true,isBigEndian:false)})
        XCTAssertNil(floats.withUnsafeBytes{PCMLevel.energy($0,bits:32,isFloat:false,isBigEndian:false)})
    }
}
