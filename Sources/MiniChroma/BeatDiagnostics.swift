import Foundation
import AppKit
import ChromaCore

/// A local synthetic full-mix groove fixture (not a copyrighted song). The diagnostic taps only its playback process.
@MainActor func runBeatDiagnostic() async{
    let previous=UserDefaults.standard.data(forKey:"lastPreset")
    defer{if let previous{UserDefaults.standard.set(previous,forKey:"lastPreset")}else{UserDefaults.standard.removeObject(forKey:"lastPreset")}}
    let rate=48000,lead=1.0
    let path=FileManager.default.temporaryDirectory.appendingPathComponent("MiniChroma-beat-\(UUID().uuidString).wav")
    var player:Process?
    var model:AppModel?
    do{
        var samples=(0..<Int(17.7*Double(rate))).map{i -> Float in
            let t=Double(i)/Double(rate)
            guard t>=lead-0.4,t<15.4 else{return 0}
            let melody=0.075*sin(2*Double.pi*440*t)+0.045*sin(2*Double.pi*660*t)
            let bass=0.12*sin(2*Double.pi*82.4*t)
            let voice=0.07*(0.7+0.3*sin(2*Double.pi*3*t))*sin(2*Double.pi*220*t+0.4*sin(2*Double.pi*5*t))
            return Float(melody+bass+voice)
        }
        var expected:[Double]=[]
        func kick(_ time:Double){let start=Int(time*Double(rate));for i in 0..<Int(0.13*Double(rate)) where start+i<samples.count{let t=Double(i)/Double(rate);samples[start+i] += Float(0.8*sin(2*Double.pi*55*t)*exp(-t/0.035))}}
        func snare(_ time:Double){let start=Int(time*Double(rate));var seed:UInt32=12345;for i in 0..<Int(0.07*Double(rate)) where start+i<samples.count{seed=1664525 &* seed &+ 1013904223;let t=Double(i)/Double(rate),noise=Double(seed)/Double(UInt32.max)*2-1;samples[start+i] += Float(noise*0.5*exp(-t/0.018))}}
        var cursor=lead
        for bpm in [120.0,150.0]{
            let scale=120/bpm
            for bar in 0..<4{
                let start=cursor+Double(bar)*2*scale
                for offset in [0.0,0.75,0.875,1.5]{let t=start+offset*scale;kick(t);expected.append(t)}
                for offset in [0.5,1.25]{let t=start+offset*scale;snare(t);expected.append(t)}
            }
            cursor += 8*scale
        }
        expected.sort()
        var wave=Data()
        func ascii(_ s:String){wave.append(Data(s.utf8))}
        func integer<T:FixedWidthInteger>(_ value:T){var little=value.littleEndian;withUnsafeBytes(of:&little){wave.append(contentsOf:$0)}}
        let bytes=UInt32(samples.count*2)
        ascii("RIFF");integer(UInt32(36)+bytes);ascii("WAVEfmt ");integer(UInt32(16));integer(UInt16(1));integer(UInt16(1));integer(UInt32(rate));integer(UInt32(rate*2));integer(UInt16(2));integer(UInt16(16));ascii("data");integer(bytes)
        for sample in samples{integer(Int16((min(1,max(-1,sample))*32767).rounded()))}
        try wave.write(to:path,options:.atomic)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/afplay");process.arguments=[path.path];try process.run();player=process
        let start=ContinuousClock.now
        try await Task.sleep(for:.milliseconds(250))
        let meter=AudioMeter(includedPID:process.processIdentifier)
        let controller=AppModel(audio:meter,monitor:false);model=controller
        controller.preset.mode = .beatAdapt;controller.preset.rate=25;controller.preset.primary=RGB(0.1,0.3,1);controller.preset.brightness=0.25;controller.preset.beatMulticolour=false;controller.preset.noiseGate=0.003;controller.preset.beatDetail=0.65
        controller.apply()
        var mainTimes:[Double]=[],pulseTimes:[Double]=[]
        var lastMain = -Double.infinity,lastReport=0.0,lastBlue=0.0
        while start.duration(to:.now) < .seconds(18){
            let elapsed=start.duration(to:.now).secondsDouble
            if let observation=meter.beat{
                let snapshot=observation.snapshot
                if snapshot.lastMain>lastMain{lastMain=snapshot.lastMain;if lastMain.isFinite{mainTimes.append(lastMain)}}
                if elapsed-lastReport>1{lastReport=elapsed;print(String(format:"BEAT time=%.2f BPM=%@ confidence=%.2f main=%d extra=%d frames=%d",elapsed,observation.bpm.map{String(format:"%.1f",$0)} ?? "listening",snapshot.confidence,snapshot.mainCount,snapshot.extraCount,controller.sentFrames))}
            }
            let blue=controller.preview.b
            if blue>0.20,blue-lastBlue>0.025,let observation=meter.beat{pulseTimes.append(observation.snapshot.time+observation.age)}
            lastBlue=blue
            try await Task.sleep(for:.milliseconds(25))
        }
        // Estimate only the fixed tap startup offset; each event must then match within 80ms.
        var bestOffset=0.0,bestMatched=0,bestError=Double.infinity
        for step in -200...100{
            let offset=Double(step)*0.005
            let match=BeatEventMatcher.match(expected:expected.map{$0+offset},detected:mainTimes,tolerance:0.08)
            if match.matched>bestMatched || (match.matched==bestMatched && match.totalError<bestError){bestMatched=match.matched;bestOffset=offset;bestError=match.totalError}
        }
        let falseHits=BeatEventMatcher.match(expected:expected.map{$0+bestOffset},detected:mainTimes,tolerance:0.08).falseHits
        let visibleMatches=BeatEventMatcher.match(expected:expected.map{$0+bestOffset},detected:pulseTimes,tolerance:0.10).matched
        print("GROOVE_RESULT expected=\(expected.count) matchedWithin80ms=\(bestMatched) falseHits=\(falseHits) visibleWithin100ms=\(visibleMatches) frames=\(controller.sentFrames) tapOffset=\(bestOffset)")
        guard Double(bestMatched)/Double(expected.count)>=0.90,falseHits<=3,Double(visibleMatches)/Double(expected.count)>=0.85,controller.sentFrames>350 else{throw ProtocolError("Full-mix groove event/pulse timing did not meet acceptance thresholds")}
        try await Task.sleep(for:.milliseconds(500))
        guard controller.preview.bytes == [0,0,0] else{throw ProtocolError("Beat fixture silence did not turn off")}
        print("BEAT_TEST_PASS · full-mix syncopated groove120→150BPM, scoped audio tap, validated USB; not the actual song or a claim for every mix")
    }catch{print("BEAT_TEST_FAIL \(error.localizedDescription)")}
    if let player,player.isRunning{player.terminate()}
    model?.cancel();await model?.waitForCleanup()
    let usb=model?.usb ?? RazerUSBActor()
    do{_ = try await usb.exchange(Commands.brightness(0));_ = try await usb.exchange(Commands.off());let reply=try await usb.exchange(Commands.getBrightness());print("BEAT_FINAL_OFF brightness=\(reply[10])/255")}catch{print("BEAT_FINAL_OFF_ERROR \(error.localizedDescription)")}
    await usb.close()
    try? FileManager.default.removeItem(at:path)
}

/// Timing/features only; never writes or retains audio samples and never changes playback or USB.
@MainActor func runBeatObservation() async{
    let meter=AudioMeter()
    let data=UserDefaults.standard.data(forKey:"lastPreset")
    let preset=data.flatMap{try? JSONDecoder().decode(Preset.self,from:$0)} ?? Preset(name:"Observation")
    meter.configureBeat(preset.beatConfiguration)
    do{
        try await meter.start()
        let start=ContinuousClock.now
        var lastMain = -Double.infinity,lastExtra = -Double.infinity,lastReport=0.0
        while start.duration(to:.now) < .seconds(25){
            if let o=meter.beat{
                let s=o.snapshot
                if s.lastMain>lastMain || s.lastExtra>lastExtra || s.time-lastReport>0.1{
                    let event=s.lastMain>lastMain ? "DRUM" : s.lastExtra>lastExtra ? "EXTRA" : "FEATURE"
                    print(String(format:"LIVE %@ t=%.3f rms=%.4f low=%.4f mid=%.4f high=%.4f lowFlux=%.4f/%.4f highFlux=%.4f/%.4f drums=%d extras=%d",event,s.time,meter.current ?? 0,s.bassLevel,s.midLevel,s.highLevel,s.bassFlux,s.bassThreshold,s.highFlux,s.highThreshold,s.mainCount,s.extraCount))
                    lastMain=s.lastMain;lastExtra=s.lastExtra;lastReport=s.time
                }
            }
            try await Task.sleep(for:.milliseconds(10))
        }
        if let s=meter.beat?.snapshot{print("LIVE_RESULT drums=\(s.mainCount) extras=\(s.extraCount) kick=\(s.kickCount) snare=\(s.snareCount) high=\(s.hatCount) learned=\(s.learnedTemplates) BPM=\(s.bpm.map{String(format:"%.1f",$0)} ?? "unlocked")")}
    }catch{print("LIVE_ERROR \(error.localizedDescription)")}
    await meter.stop()
}


/// Observe current music through the normal global tap, validate RGB USB replies,
/// preserve settings, and finish off. No playback changes or audio recording.
@MainActor func runPercussionLiveDiagnostic() async{
    let previous=UserDefaults.standard.data(forKey:"lastPreset")
    defer{if let previous{UserDefaults.standard.set(previous,forKey:"lastPreset")}else{UserDefaults.standard.removeObject(forKey:"lastPreset")}}
    let meter=AudioMeter()
    // Use the same meter for observations and the controller.
    let controller=AppModel(audio:meter,monitor:false)
    controller.preset.mode = .beatAdapt;controller.preset.rate=25;controller.preset.beatMulticolour=true
    controller.apply()
    let start=ContinuousClock.now
    var report=0.0
    while start.duration(to:.now) < .seconds(20){
        if let observation=meter.beat,observation.snapshot.time-report>1{
            let s=observation.snapshot;report=s.time
            print("PERCUSSION_LIVE t=\(String(format:"%.2f",s.time)) kick=\(s.kickCount) snare=\(s.snareCount) high=\(s.hatCount) learned=\(s.learnedTemplates) probation=\(s.learningTemplates) frames=\(controller.sentFrames)")
        }
        try? await Task.sleep(for:.milliseconds(25))
    }
    if let s=meter.beat?.snapshot{print("PERCUSSION_RESULT kick=\(s.kickCount) snare=\(s.snareCount) high=\(s.hatCount) learned=\(s.learnedTemplates) frames=\(controller.sentFrames) status=\(controller.status)")}
    else{print("PERCUSSION_RESULT no audio samples; capture permission or playback needs user check")}
    controller.cancel();await controller.waitForCleanup()
    do{_ = try await controller.usb.exchange(Commands.brightness(0));_ = try await controller.usb.exchange(Commands.off());let reply=try await controller.usb.exchange(Commands.getBrightness());print("PERCUSSION_FINAL_OFF brightness=\(reply[10])/255")}catch{print("PERCUSSION_FINAL_OFF_ERROR \(error.localizedDescription)")}
    await controller.usb.close()
}
