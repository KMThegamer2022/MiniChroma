import XCTest
@testable import ChromaCore
final class AudioEnvelopeTests:XCTestCase{
    private func audioPreset()->Preset{var p=Preset(name:"Audio");p.mode = .audio;p.gain=10;p.noiseGate=0;p.smoothing=0.15;return p}
    func testEnvelopeInterpolatesEveryFrameBeforeMappingHue(){
        let p=audioPreset();var envelope=AudioEnvelope()
        let first=envelope.color(rms:0.1,preset:p,dt:0.04)
        let second=envelope.color(rms:0.1,preset:p,dt:0.04)
        XCTAssertNotEqual(first,second,"Unchanged callback input must still interpolate between frame ticks")
        XCTAssertGreaterThan(first.g,0,"Attack should not jump directly to fully red")
        XCTAssertGreaterThan(second.r,first.r)
        for _ in 0..<20{_ = envelope.color(rms:0.1,preset:p,dt:0.04)}
        XCTAssertGreaterThan(envelope.level,0.99)
    }
    func testBriefDropoutHoldsThenFadesAndSilenceReachesExactOff(){
        let p=audioPreset();var envelope=AudioEnvelope()
        for _ in 0..<15{_ = envelope.color(rms:0.1,preset:p,dt:0.04)}
        let gap=envelope.color(rms:nil,preset:p,dt:0.04)
        XCTAssertNotEqual(gap,.black,"A brief gap must not flicker straight off")
        let fading=envelope.color(rms:0,preset:p,dt:0.04)
        XCTAssertNotEqual(fading,.black)
        XCTAssertEqual(envelope.color(rms:0,preset:p,dt:0.04),.black)
        XCTAssertEqual(envelope.color(rms:.nan,preset:p,dt:0.04),.black)
    }
    func testAttackUsesElapsedTimeInsteadOfFrameCount(){
        let p=audioPreset();var once=AudioEnvelope(),many=AudioEnvelope()
        _ = once.color(rms:0.1,preset:p,dt:1)
        for _ in 0..<25{_ = many.color(rms:0.1,preset:p,dt:0.04)}
        XCTAssertEqual(once.level,many.level,accuracy:0.000001)
    }
}
