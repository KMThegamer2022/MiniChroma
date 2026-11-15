import Foundation
import CoreAudio
import IOKit.ps

struct SystemInputs {
    static func volume() -> (Double,Bool)? {
        var device=AudioDeviceID(0);var size=UInt32(MemoryLayout.size(ofValue:device))
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device)==noErr,device != 0 else{return nil}
        var mute:UInt32=0;size=4;address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyMute,mScope:kAudioDevicePropertyScopeOutput,mElement:0)
        _=AudioObjectGetPropertyData(device,&address,0,nil,&size,&mute)
        var values:[Double]=[]
        for channel:UInt32 in [0,1,2] {
            var value:Float32=0;size=4;address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyVolumeScalar,mScope:kAudioDevicePropertyScopeOutput,mElement:channel)
            if AudioObjectGetPropertyData(device,&address,0,nil,&size,&value)==noErr { values.append(Double(value));if channel==0 {break} }
        }
        guard !values.isEmpty else{return nil};return (values.reduce(0,+)/Double(values.count),mute != 0)
    }
    static func battery() -> (Double,Bool)? {
        guard let info=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources=IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else{return nil}
        for source in sources {
            guard let d=IOPSGetPowerSourceDescription(info,source)?.takeUnretainedValue() as? [String:Any],d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,let current=d[kIOPSCurrentCapacityKey] as? Double,let maximum=d[kIOPSMaxCapacityKey] as? Double,maximum>0 else{continue}
            return (current/maximum,d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }
}

import ChromaCore

struct AudioCaptureFailure:Error,LocalizedError,Sendable {
    let message:String
    let requiresUserAction:Bool
    var errorDescription:String?{message}
    static func classify(_ error:Error)->Self{
        if let known=error as? Self{return known}
        let e=error as NSError
        let blocked=e.domain==NSOSStatusErrorDomain && [Int(kAudioDevicePermissionsError),Int(0x7065726d),-54].contains(e.code)
        return Self(message:e.localizedDescription,requiresUserAction:blocked)
    }
}
@MainActor protocol AudioCapturing:AnyObject {
    var current:Double?{get}
    var failure:AudioCaptureFailure?{get}
    var needsRestart:Bool{get}
    var beat:BeatObservation?{get}
    func configureBeat(_ configuration:BeatConfiguration?)
    func start() async throws
    func stop() async
}
struct BeatObservation:Sendable{
    let snapshot:BeatSnapshot
    let age:Double
    var bpm:Double?{var current=snapshot;current.time += age;return current.bpm}
}
extension AudioCapturing{
    var beat:BeatObservation?{nil}
    func configureBeat(_ configuration:BeatConfiguration?){}
}
/// Audio-only CoreAudio tap. No screen, display, or microphone APIs.
@MainActor final class AudioMeter:AudioCapturing {
    private let engine:AudioTapEngine
    init(includedPID:pid_t?=nil){engine=AudioTapEngine(includedPID:includedPID)}
    private var generation=UUID()
    var current:Double?{engine.samples.current}
    var failure:AudioCaptureFailure?{engine.samples.failure}
    var needsRestart:Bool{engine.needsRestart}
    var beat:BeatObservation?{engine.samples.beat}
    func configureBeat(_ configuration:BeatConfiguration?){engine.samples.configureBeat(configuration)}
    func start() async throws{
        let token=generation
        try await engine.start(epoch:token)
        guard generation==token,!Task.isCancelled else{await engine.stop(expected:token);throw CancellationError()}
    }
    func stop() async{generation=UUID();await engine.stop()}
}
final class TapSamples:@unchecked Sendable {
    private let lock=NSLock()
    private var epoch:UUID?
    private var level=0.0,timestamp = -Double.infinity,lastHealthCheck=0.0
    private var active=false
    private var device=AudioObjectID(0)
    private var issue:AudioCaptureFailure?
    private var beatConfiguration:BeatConfiguration?
    private var detector:BeatDetector?
    private var beatTimestamp = -Double.infinity
    var beat:BeatObservation?{lock.withLock{guard let detector,beatTimestamp.isFinite else{return nil};return BeatObservation(snapshot:detector.snapshot,age:max(0,ProcessInfo.processInfo.systemUptime-beatTimestamp))}}
    var analyzesBeat:Bool{lock.withLock{beatConfiguration != nil}}
    func configureBeat(_ configuration:BeatConfiguration?){lock.withLock{beatConfiguration=configuration;detector=configuration.map{BeatDetector(configuration:$0)};beatTimestamp = -Double.infinity}}
    func analyze(_ mono:[Float],sampleRate:Double,epoch token:UUID,time:Double=ProcessInfo.processInfo.systemUptime){lock.withLock{
        guard epoch==token,active else{return}
        if beatTimestamp.isFinite,time-beatTimestamp>2{detector=beatConfiguration.map{BeatDetector(configuration:$0)}}
        detector?.process(mono,sampleRate:sampleRate);beatTimestamp=time
    }}
    var current:Double?{lock.withLock{ProcessInfo.processInfo.systemUptime-timestamp<0.08 ? level : nil}}
    var failure:AudioCaptureFailure?{lock.withLock{issue}}
    func begin(_ token:UUID){lock.withLock{epoch=token;level=0;timestamp = -Double.infinity;active=false;issue=nil;device=0;detector=beatConfiguration.map{BeatDetector(configuration:$0)};beatTimestamp = -Double.infinity}}
    func activate(device:AudioObjectID,epoch token:UUID){lock.withLock{guard epoch==token else{return};self.device=device;active=true}}
    func clear(){lock.withLock{epoch=nil;level=0;timestamp = -Double.infinity;active=false;device=0;issue=nil;detector=beatConfiguration.map{BeatDetector(configuration:$0)};beatTimestamp = -Double.infinity}}
    func fail(_ failure:AudioCaptureFailure){lock.withLock{issue=failure;active=false;level=0;timestamp = -Double.infinity}}
    func record(_ value:Double,epoch token:UUID){lock.withLock{guard epoch==token,active else{return};level=value;timestamp=ProcessInfo.processInfo.systemUptime}}
    func health()->Bool{
        let snapshot:(Bool,AudioObjectID,Bool)=lock.withLock{
            if issue != nil || !active{return(false,0,false)}
            let now=ProcessInfo.processInfo.systemUptime
            guard now-lastHealthCheck>1 else{return(true,device,false)}
            lastHealthCheck=now;return(true,device,true)
        }
        guard snapshot.0 else{return false}
        if snapshot.2{
            var alive:UInt32=0,size=UInt32(MemoryLayout<UInt32>.size)
            var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceIsAlive,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            let result=AudioObjectGetPropertyData(snapshot.1,&address,0,nil,&size,&alive)
            if result != noErr || alive==0{fail(AudioCaptureFailure(message:"Audio tap device became unavailable",requiresUserAction:false));return false}
        }
        return true
    }
}
private final class AudioTapEngine:@unchecked Sendable {
    let samples=TapSamples()
    private let control=DispatchQueue(label:"MiniChroma.audio.control")
    private let callbacks=DispatchQueue(label:"MiniChroma.audio.samples",qos:.userInitiated)
    private var tap=AudioObjectID(0),aggregate=AudioObjectID(0)
    private var ioProc:AudioDeviceIOProcID?
    private var activeEpoch:UUID?
    private let includedPID:pid_t?
    init(includedPID:pid_t?=nil){self.includedPID=includedPID}
    var needsRestart:Bool{!samples.health()}
    func start(epoch:UUID) async throws{
        try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in
            control.async{
                self.stopLocked();self.activeEpoch=epoch;self.samples.begin(epoch)
                do{
                    var ownProcess=AudioObjectID(0),size=UInt32(MemoryLayout<AudioObjectID>.size),pid=getpid()
                    var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyTranslatePIDToProcessObject,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
                    _=AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,UInt32(MemoryLayout<pid_t>.size),&pid,&size,&ownProcess)
                    let description:CATapDescription
                    if var includedPID=self.includedPID{
                        var process=AudioObjectID(0);size=UInt32(MemoryLayout<AudioObjectID>.size)
                        _=AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,UInt32(MemoryLayout<pid_t>.size),&includedPID,&size,&process)
                        guard process != 0 else{throw AudioCaptureFailure(message:"Diagnostic playback process has no audio object",requiresUserAction:false)}
                        description=CATapDescription(stereoMixdownOfProcesses:[process])
                    }else{description=CATapDescription(stereoGlobalTapButExcludeProcesses:ownProcess==0 ? [] : [ownProcess])}
                    description.name="MiniChroma system audio";description.uuid=UUID();description.isPrivate=true;description.muteBehavior = .unmuted
                    let creation=AudioHardwareCreateProcessTap(description,&self.tap)
                    guard creation==noErr else{throw AudioCaptureFailure(message:"Cannot create audio-only tap (\(creation)). Allow System Audio Recording for MiniChroma, then click Apply.",requiresUserAction:true)}
                    var format=AudioStreamBasicDescription();size=UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    address=AudioObjectPropertyAddress(mSelector:kAudioTapPropertyFormat,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
                    try Self.check(AudioObjectGetPropertyData(self.tap,&address,0,nil,&size,&format),stage:"read tap format")
                    guard format.mFormatID==kAudioFormatLinearPCM,format.mFormatFlags & kAudioFormatFlagIsFloat != 0,[32,64].contains(format.mBitsPerChannel)else{throw AudioCaptureFailure(message:"Unsupported audio tap PCM format",requiresUserAction:true)}
                    let composition:[String:Any]=[
                        kAudioAggregateDeviceNameKey:"MiniChroma private audio",
                        kAudioAggregateDeviceUIDKey:UUID().uuidString,
                        kAudioAggregateDeviceIsPrivateKey:true,
                        kAudioAggregateDeviceTapAutoStartKey:true,
                        kAudioAggregateDeviceTapListKey:[[kAudioSubTapUIDKey:description.uuid.uuidString,kAudioSubTapDriftCompensationKey:true]]
                    ]
                    try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary,&self.aggregate),stage:"create private audio device")
                    let asbd=format,state=self.samples
                    try Self.check(AudioDeviceCreateIOProcIDWithBlock(&self.ioProc,self.aggregate,self.callbacks){_,input,_,_,_ in
                        var sum=0.0,count=0
                        let buffers=UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:input))
                        for buffer in buffers{
                            guard let data=buffer.mData else{continue}
                            if let energy=PCMLevel.energy(UnsafeRawBufferPointer(start:data,count:Int(buffer.mDataByteSize)),bits:asbd.mBitsPerChannel,isFloat:asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,isBigEndian:asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0){sum += energy.sum;count += energy.count}
                        }
                        if count>0{state.record(sqrt(sum/Double(count)),epoch:epoch)}
                        if state.analyzesBeat{
                            let width=Int(asbd.mBitsPerChannel/8)
                            let frameCount=buffers.map{Int($0.mDataByteSize)/max(1,width*Int($0.mNumberChannels))}.max() ?? 0
                            var mono=[Float](repeating:0,count:frameCount)
                            for frame in 0..<frameCount{
                                var value=0.0,channels=0
                                for buffer in buffers{
                                    guard let data=buffer.mData else{continue}
                                    let bytes=UnsafeRawBufferPointer(start:data,count:Int(buffer.mDataByteSize)),channelCount=Int(buffer.mNumberChannels)
                                    for channel in 0..<channelCount{if let sample=PCMLevel.sample(bytes,index:frame*channelCount+channel,bits:asbd.mBitsPerChannel,isBigEndian:asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0){value += sample;channels += 1}}
                                }
                                mono[frame]=Float(channels>0 ? value/Double(channels) : 0)
                            }
                            state.analyze(mono,sampleRate:asbd.mSampleRate,epoch:epoch)
                        }
                    },stage:"create audio callback")
                    self.samples.activate(device:self.aggregate,epoch:epoch)
                    try Self.check(AudioDeviceStart(self.aggregate,self.ioProc),stage:"start audio tap")
                    continuation.resume()
                }catch{
                    let failure=AudioCaptureFailure.classify(error);self.stopLocked();self.samples.fail(failure);continuation.resume(throwing:failure)
                }
            }
        }
    }
    func stop(expected:UUID?=nil) async{
        await withCheckedContinuation{continuation in control.async{
            if expected==nil || self.activeEpoch==expected{self.stopLocked()}
            continuation.resume()
        }}
    }
    private func stopLocked(){
        samples.clear();activeEpoch=nil
        if aggregate != 0,let ioProc{AudioDeviceStop(aggregate,ioProc);AudioDeviceDestroyIOProcID(aggregate,ioProc)}
        ioProc=nil
        if aggregate != 0{AudioHardwareDestroyAggregateDevice(aggregate);aggregate=0}
        if tap != 0{AudioHardwareDestroyProcessTap(tap);tap=0}
    }
    private static func check(_ status:OSStatus,stage:String)throws{
        guard status==noErr else{throw AudioCaptureFailure(message:"Cannot \(stage) (\(status))",requiresUserAction:AudioCaptureFailure.classify(NSError(domain:NSOSStatusErrorDomain,code:Int(status))).requiresUserAction)}
    }
}
