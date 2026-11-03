import XCTest
@testable import ChromaCore
final class TemperatureTests:XCTestCase {
    func testTemperatureThresholdsDriveColoursAndMissingReadingStaysUnavailable() {
        var p=Preset(name:"CPU");p.mode = .temperature;p.cool=40;p.hot=80
        XCTAssertEqual(p.color(time:0,input:40),RGB(0,1,0))
        XCTAssertEqual(p.color(time:0,input:64),RGB(1,1,0))
        XCTAssertEqual(p.color(time:0,input:80),RGB(1,0,0))
        XCTAssertNil(p.color(time:0,input:nil))
    }
    func testTemperatureDecodesLittleEndianFloatAndSignedFixedPoint() {
        XCTAssertEqual(TemperatureReading.decode(type:0x666c7420,bytes:[0,0,72,66]),50)
        XCTAssertEqual(TemperatureReading.decode(type:0x73703738,bytes:[50,128]),50.5)
        XCTAssertNil(TemperatureReading.decode(type:0x666c7420,bytes:[0,0,128,127]))
        XCTAssertNil(TemperatureReading.decode(type:0x73703738,bytes:[255,0]))
        XCTAssertNil(TemperatureReading.decode(type:0x75693820,bytes:[50]))
    }
    func testHottestValidCPUSensorIsSelected() {
        let result=TemperatureReading.hottest(["Te05":42,"Tp01":58.5,"Tp05":400,"Te09":Double.nan])
        XCTAssertEqual(result?.celsius,58.5)
        XCTAssertEqual(result?.key,"Tp01")
        XCTAssertNil(TemperatureReading.hottest([:]))
    }
}
