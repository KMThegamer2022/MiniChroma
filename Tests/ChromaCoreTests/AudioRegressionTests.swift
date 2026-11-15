import XCTest
import ChromaCore
import CoreAudio
@testable import MiniChroma

final class AudioRegressionTests:XCTestCase {
    func testSilentCallbackGapResetsPercussionHistoryWithoutRestartingCapture(){
        let samples=TapSamples(),epoch=UUID()
        samples.configureBeat(BeatConfiguration());samples.begin(epoch);samples.activate(device:1,epoch:epoch)
        samples.analyze(BeatFixture.samples(segments:[(120,4)],sampleRate:8000),sampleRate:8000,epoch:epoch,time:100)
        XCTAssertGreaterThan(samples.beat?.snapshot.learnedTemplates ?? 0,0)
        samples.analyze([Float](repeating:0,count:40),sampleRate:8000,epoch:epoch,time:103)
        XCTAssertEqual(samples.beat?.snapshot.learnedTemplates,0)
        XCTAssertEqual(samples.beat?.snapshot.mainCount,0)
        XCTAssertLessThan(samples.beat?.snapshot.time ?? 1,0.01)
        XCTAssertNil(samples.failure)
    }
    func testAudioUsesGreenYellowRedAndGateGivesExactBlack() {
        var p=Preset(name:"Audio");p.mode = .audio;p.gain=10;p.noiseGate=0.005;p.primary=RGB(0,0,1)
        let quiet=p.color(time:0,input:0.01)!
        XCTAssertEqual(quiet.r,5.0/57,accuracy:0.000001);XCTAssertEqual(quiet.g,1);XCTAssertEqual(quiet.b,0)
        let yellow=p.color(time:0,input:0.062)!
        XCTAssertEqual(yellow.r,1,accuracy:0.000001);XCTAssertEqual(yellow.g,1,accuracy:0.000001);XCTAssertEqual(yellow.b,0)
        XCTAssertEqual(p.color(time:0,input:0.1),RGB(1,0,0))
        XCTAssertEqual(p.color(time:0,input:0.005),.black)
        XCTAssertEqual(p.color(time:0,input:nil),.black)
        XCTAssertEqual(p.color(time:0,input:Double.nan),.black)
        XCTAssertEqual(p.color(time:0,input:Double.infinity),.black)
        p.gain=0;XCTAssertEqual(p.color(time:0,input:0.5),.black)
        p.gain = .nan;XCTAssertEqual(p.color(time:0,input:0.5),.black)
    }
    @MainActor func testAudioStartWaitsForPreviousStopAndWakeRestarts() async throws {
        let audio=FakeAudio();audio.stopDelay=0.08
        let model=AppModel(usb:fakeUSB(),audio:audio,monitor:false)
        model.preset.mode = .audio;model.apply()
        try await Task.sleep(for:.milliseconds(180))
        XCTAssertTrue(audio.running,"Previous cleanup must finish before new capture starts")
        model.handleSleep();model.handleWake()
        try await Task.sleep(for:.milliseconds(220))
        XCTAssertTrue(audio.running)
        XCTAssertTrue(model.active)
        XCTAssertGreaterThanOrEqual(audio.starts,2)
        model.stop();try await Task.sleep(for:.milliseconds(100))
    }
    @MainActor func testStaleAudioSendsBlackAndRestartsCapture() async throws {
        let audio=FakeAudio()
        let packets=FrameCapture()
        let usb=RazerUSBActor{request in packets.add(request);var reply=request;reply[0]=2;return reply}
        let model=AppModel(usb:usb,audio:audio,monitor:false)
        model.preset.mode = .audio;model.preset.rate=25;model.preset.smoothing=2;model.apply()
        try await Task.sleep(for:.milliseconds(160))
        audio.level=nil
        try await Task.sleep(for:.milliseconds(180))
        XCTAssertEqual(packets.lastRGB,[0,0,0],"Stale samples must not leave the previous light on")
        audio.failure=AudioCaptureFailure(message:"System stopped capture",requiresUserAction:false)
        try await Task.sleep(for:.milliseconds(250))
        XCTAssertGreaterThanOrEqual(audio.starts,2)
        model.stop();try await Task.sleep(for:.milliseconds(30))
    }
    @MainActor func testSilenceBypassesLongSmoothingAndUserStopDoesNotRestart() async throws {
        let audio=FakeAudio();let packets=FrameCapture()
        let usb=RazerUSBActor{r in packets.add(r);var reply=r;reply[0]=2;return reply}
        let model=AppModel(usb:usb,audio:audio,monitor:false)
        model.preset.mode = .audio;model.preset.rate=25;model.preset.smoothing=5;model.apply()
        try await Task.sleep(for:.milliseconds(160));audio.level=0
        try await Task.sleep(for:.milliseconds(180));XCTAssertEqual(packets.lastRGB,[0,0,0])
        audio.failure=AudioCaptureFailure(message:"User stopped capture",requiresUserAction:true)
        let starts=audio.starts
        try await Task.sleep(for:.milliseconds(200));XCTAssertEqual(audio.starts,starts)
        model.stop();try await Task.sleep(for:.milliseconds(30))
    }
    @MainActor func testRecoverableStartupFailureRetriesButDeniedCaptureWaitsForApply() async throws {
        let transient=FakeAudio();transient.startFailures=[AudioCaptureFailure(message:"System stopped stream",requiresUserAction:false)]
        let model=AppModel(usb:fakeUSB(),audio:transient,monitor:false);model.preset.mode = .audio;model.apply()
        try await Task.sleep(for:.milliseconds(200));XCTAssertGreaterThanOrEqual(transient.starts,2);XCTAssertTrue(model.active)
        model.stop();try await Task.sleep(for:.milliseconds(30))
        let denied=FakeAudio();denied.startFailures=[AudioCaptureFailure(message:"Permission denied",requiresUserAction:true)]
        let blocked=AppModel(usb:fakeUSB(),audio:denied,monitor:false);blocked.preset.mode = .audio;blocked.apply()
        try await Task.sleep(for:.milliseconds(100));blocked.handleSleep();blocked.handleWake()
        try await Task.sleep(for:.milliseconds(150));XCTAssertEqual(denied.starts,1);XCTAssertFalse(blocked.active)
        blocked.stop();try await Task.sleep(for:.milliseconds(30))
    }
    func testAudioTapPermissionFailureWaitsForUserAction(){
        XCTAssertTrue(AudioCaptureFailure.classify(NSError(domain:NSOSStatusErrorDomain,code:Int(kAudioDevicePermissionsError))).requiresUserAction)
        XCTAssertFalse(AudioCaptureFailure.classify(NSError(domain:NSOSStatusErrorDomain,code:Int(kAudioHardwareBadDeviceError))).requiresUserAction)
    }
    @MainActor func testHealthySilentAudioDoesNotReauthorizeOrRestart() async throws{
        let audio=FakeAudio();audio.level=nil
        let model=AppModel(usb:fakeUSB(),audio:audio,monitor:false);model.preset.mode = .audio;model.apply()
        try await Task.sleep(for:.milliseconds(2300))
        XCTAssertEqual(audio.starts,1,"Healthy silence must not repeatedly create capture/permission requests")
        model.stop();await model.waitForCleanup()
    }
    @MainActor func testTwentyFiveHzRendersWithoutWaitingForNewAudioSamples() async throws{
        let audio=FakeAudio();let packets=FrameCapture()
        let usb=RazerUSBActor{request in packets.add(request);var reply=request;reply[0]=2;return reply}
        let model=AppModel(usb:usb,audio:audio,monitor:false);model.preset.mode = .audio;model.preset.rate=25;model.apply()
        try await Task.sleep(for:.milliseconds(550))
        let times=packets.frameTimes
        XCTAssertGreaterThanOrEqual(times.count,11);XCTAssertLessThanOrEqual(times.count,17)
        if let first=times.first,let last=times.last,times.count>1{XCTAssertEqual((last-first)/Double(times.count-1),0.04,accuracy:0.015)}
        model.stop();await model.waitForCleanup()
    }
    func testRecoveryAttemptsAreBoundedAndFreshSampleResetsBudget() {
        var recovery=AudioRecovery(now:0)
        XCTAssertFalse(recovery.shouldRestart(now:1,hasSample:false,failed:false))
        var attempts=0
        for second in 0...120 {if recovery.shouldRestart(now:Double(second),hasSample:false,failed:true){attempts += 1;recovery.didRestart(now:Double(second))}}
        XCTAssertEqual(attempts,5)
        XCTAssertFalse(recovery.shouldRestart(now:200,hasSample:true,failed:false))
        XCTAssertTrue(recovery.shouldRestart(now:204,hasSample:false,failed:true))
    }
    private func fakeUSB()->RazerUSBActor{RazerUSBActor{r in var reply=r;reply[0]=2;return reply}}
}

@MainActor private final class FakeAudio:AudioCapturing {
    var level:Double?=0.2
    var failure:AudioCaptureFailure?
    var running=false;var starts=0;var stopDelay=0.0
    var startFailures:[AudioCaptureFailure]=[]
    var current:Double?{running ? level : nil}
    var needsRestart:Bool{failure != nil || !running}
    func start() async throws{starts += 1;if !startFailures.isEmpty{let next=startFailures.removeFirst();failure=next;running=false;throw next};running=true;failure=nil}
    func stop() async{if stopDelay>0{try? await Task.sleep(for:.seconds(stopDelay))};running=false;failure=nil}
}
private final class FrameCapture:@unchecked Sendable{
    let lock=NSLock();private var rgb:[UInt8]?
    private var times:[Double]=[]
    var frameTimes:[Double]{lock.withLock{times}}
    var lastRGB:[UInt8]?{lock.withLock{rgb}}
    func add(_ request:[UInt8]){if request[6]==15,request[7]==3{lock.withLock{rgb=Array(request[13...15]);times.append(ProcessInfo.processInfo.systemUptime)}}}
}
