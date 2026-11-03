import Foundation
import CoreAudio
import IOKit.ps
import ScreenCaptureKit
import CoreMedia

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

final class AudioMeter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock=NSLock();private var level=0.0;private var timestamp=Date.distantPast
    @MainActor private var stream:SCStream?
    @MainActor private var generation=UUID()
    var current:Double? { lock.lock();defer{lock.unlock()};return Date().timeIntervalSince(timestamp)<2 ? level : nil }
    @MainActor func start() async throws {
        if stream != nil{return}
        let token=generation
        let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        guard generation == token,!Task.isCancelled else{throw CancellationError()}
        guard let display=content.displays.first else{throw NSError(domain:"MiniChroma",code:1,userInfo:[NSLocalizedDescriptionKey:"No display available for system audio capture"])}
        let config=SCStreamConfiguration();config.capturesAudio=true;config.excludesCurrentProcessAudio=true;config.sampleRate=48000;config.channelCount=2;config.width=2;config.height=2;config.minimumFrameInterval=CMTime(value:1,timescale:1)
        let capture=SCStream(filter:SCContentFilter(display:display,excludingApplications:[],exceptingWindows:[]),configuration:config,delegate:nil)
        try capture.addStreamOutput(self,type:.audio,sampleHandlerQueue:DispatchQueue(label:"MiniChroma.audio"))
        try await capture.startCapture()
        guard generation == token,!Task.isCancelled else{try? await capture.stopCapture();throw CancellationError()}
        stream=capture
    }
    @MainActor func stop() async { generation=UUID();let old=stream;stream=nil;try? await old?.stopCapture();lock.withLock{timestamp = .distantPast;level=0} }
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType) {
        guard type == .audio,CMSampleBufferIsValid(sampleBuffer) else{return}
        guard let format=CMSampleBufferGetFormatDescription(sampleBuffer),let description=CMAudioFormatDescriptionGetStreamBasicDescription(format),description.pointee.mBitsPerChannel == 32,description.pointee.mFormatID == kAudioFormatLinearPCM,description.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 else{return}
        var needed=0;var block:CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,bufferListSizeNeededOut:&needed,bufferListOut:nil,bufferListSize:0,blockBufferAllocator:nil,blockBufferMemoryAllocator:nil,flags:0,blockBufferOut:&block)==noErr else{return}
        let storage=UnsafeMutableRawPointer.allocate(byteCount:needed,alignment:16);defer{storage.deallocate()}
        let list=storage.bindMemory(to:AudioBufferList.self,capacity:1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,bufferListSizeNeededOut:nil,bufferListOut:list,bufferListSize:needed,blockBufferAllocator:nil,blockBufferMemoryAllocator:nil,flags:kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,blockBufferOut:&block)==noErr else{return}
        var sum=0.0,count=0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data=buffer.mData else{continue};let n=Int(buffer.mDataByteSize)/4
            let values=data.assumingMemoryBound(to:Float.self)
            for i in 0..<n {let v=Double(values[i]);if v.isFinite{sum += v*v;count += 1}}
        }
        guard count>0 else{return};lock.withLock{level=sqrt(sum/Double(count));timestamp=Date()}
    }
}
