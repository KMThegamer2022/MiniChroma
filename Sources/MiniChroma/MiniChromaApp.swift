import SwiftUI
import AppKit
import ServiceManagement
import ChromaCore

@main struct MiniChromaApp: App {
    @StateObject private var model=AppModel(monitor: !CommandLine.arguments.contains("--percussion-live-test") && !CommandLine.arguments.contains("--beat-observe") && !CommandLine.arguments.contains("--preview") && !CommandLine.arguments.contains("--audio-test") && !CommandLine.arguments.contains("--audio-recovery-test") && !CommandLine.arguments.contains("--beat-test") && !CommandLine.arguments.contains("--system-test") && !CommandLine.arguments.contains("--show-colours"))
    init(){
        if CommandLine.arguments.contains("--percussion-live-test"){
            Task{@MainActor in await runPercussionLiveDiagnostic();NSApplication.shared.terminate(nil)}
        }
        if CommandLine.arguments.contains("--beat-observe"){
            Task{@MainActor in await runBeatObservation();NSApplication.shared.terminate(nil)}
        }
        if CommandLine.arguments.contains("--beat-test"){
            setbuf(stdout,nil)
            Task{@MainActor in await runBeatDiagnostic();NSApplication.shared.terminate(nil)}
        }
        if CommandLine.arguments.contains("--show-colours"){
            Task{@MainActor in let preview=AppModel(monitor:false);let target:PresetColourTarget=CommandLine.arguments.contains("--kick") ? .kick : CommandLine.arguments.contains("--snare") ? .snare : CommandLine.arguments.contains("--hat") ? .hat : .primary;preview.showColourEditor(target:target)}
        }
        if CommandLine.arguments.contains("--audio-test"){
            setbuf(stdout,nil)
            Task{@MainActor in await runAudioDiagnostic();NSApplication.shared.terminate(nil)}
        }
        if CommandLine.arguments.contains("--audio-recovery-test"){
            upgradeStoredAudioRate()
            setbuf(stdout,nil)
            Task{@MainActor in await runAudioRecoveryDiagnostic();NSApplication.shared.terminate(nil)}
        }
        if CommandLine.arguments.contains("--system-test"){
            setbuf(stdout,nil)
            Task{@MainActor in await runSystemDiagnostic();NSApplication.shared.terminate(nil)}
        }
        if CommandLine.arguments.contains("--telemetry-check"){
            if let v=SystemInputs.volume(){print("System volume: \(v.0); muted: \(v.1)")}else{print("System volume: unavailable for output device")}
            if let b=SystemInputs.battery(){print("Mac battery: \(b.0); charging: \(b.1)")}else{print("Mac battery: unavailable")}
            print("CPU temperature: read-only experimental AppleSMC; use --system-test for a live sensor/USB check")
            exit(0)
        }
    }
    var body:some Scene {
        MenuBarExtra { ControlView(model:model).frame(width:340).padding() } label: { Image(systemName:model.active ? "computermouse.fill" : "computermouse") }
            .menuBarExtraStyle(.window)
        Window("MiniChroma Settings",id:"settings") { SettingsView(model:model).frame(width:480).padding(24) }
        Window("MiniChroma Diagnostics",id:"diagnostics") { DiagnosticsView(model:model).frame(width:580,height:500).padding(24) }
    }
}

@MainActor private func upgradeStoredAudioRate(){
    let defaults=UserDefaults.standard
    guard !defaults.bool(forKey:"audio25HzUpgrade20261111")else{return}
    if let data=defaults.data(forKey:"lastPreset"),var saved=try? JSONDecoder().decode(Preset.self,from:data),saved.mode == .audio{
        saved.rate=25;defaults.set(try? JSONEncoder().encode(saved),forKey:"lastPreset")
    }
    defaults.set(true,forKey:"audio25HzUpgrade20261111")
}

@MainActor private func runAudioRecoveryDiagnostic() async{
    let previous=UserDefaults.standard.data(forKey:"lastPreset")
    defer{if let previous{UserDefaults.standard.set(previous,forKey:"lastPreset")}else{UserDefaults.standard.removeObject(forKey:"lastPreset")}}
    let model=AppModel(monitor:false)
    func tone(_ scale:Double) async throws -> (Double,Bool,Bool){
        let player=Process();player.executableURL=URL(fileURLWithPath:"/usr/bin/afplay");player.arguments=["-v",String(scale),"/System/Library/Sounds/Glass.aiff"]
        try player.run();defer{if player.isRunning{player.terminate()}}
        var peak=0.0,green=false,red=false
        for _ in 0..<45{
            peak=max(peak,model.audio.current ?? 0)
            let rgb=model.preview.bytes;green = green || (rgb[1]>rgb[0] && rgb[1]>0 && rgb[2]==0);red = red || (rgb[0]>rgb[1] && rgb[0]>0 && rgb[2]==0)
            try await Task.sleep(for:.milliseconds(25))
        }
        return (peak,green,red)
    }
    do{
        model.preset.mode = .audio;model.preset.rate=25;model.preset.brightness=0.2;model.preset.gain=15;model.preset.noiseGate=0.001;model.preset.smoothing=0
        model.apply();try await Task.sleep(for:.seconds(1))
        let baseline=model.audio.current ?? 0
        let isolated=baseline<=model.preset.noiseGate
        print("BASELINE RMS=\(baseline) isolatedTestAudio=\(isolated)")
        let quiet=try await tone(0.1);print("QUIET peakRMS=\(quiet.0) greenObserved=\(quiet.1)")
        let loud=try await tone(1);print("LOUD peakRMS=\(loud.0) redObserved=\(loud.2)")
        if isolated{
            guard loud.2,loud.0>quiet.0 else{throw ProtocolError("Loud audio colour check failed")}
            if quiet.0>model.preset.noiseGate{guard quiet.1 else{throw ProtocolError("Quiet audio colour check failed")}}
            else{print("QUIET_BELOW_GATE · signal did not exceed noise gate; green observation not claimed")}
        }else{print("ISOLATED_COLOUR_CHECK_SKIPPED · other system audio is playing; numerical mapping is covered by regression tests")}
        try await Task.sleep(for:.seconds(1.3))
        print("SILENCE RGB=\(model.preview.bytes)")
        if let sample=model.audio.current,sample>model.preset.noiseGate{print("SILENCE_NOT_PRESENT RMS=\(sample) · other system audio was not muted")}
        else{guard model.preview.bytes == [0,0,0] else{throw ProtocolError("Silence did not turn the light fully off")}}
        model.handleSleep();model.handleWake();try await Task.sleep(for:.seconds(1.3))
        let afterWake=try await tone(1)
        print("SIMULATED_WAKE frames=\(model.sentFrames) freshSample=\(model.audio.current != nil) redObserved=\(afterWake.2)")
        guard model.active,model.sentFrames>20,model.audio.current != nil,afterWake.0>0 else{throw ProtocolError("Audio did not recover after simulated sleep/wake")}
        await model.audio.stop();try await Task.sleep(for:.seconds(3))
        let restarted=try await tone(0.1)
        print("STALE_CAPTURE_RESTART freshSample=\(model.audio.current != nil) greenObserved=\(restarted.1)")
        guard model.active,model.audio.current != nil,restarted.0>0 else{throw ProtocolError("Stale audio capture did not restart")}
        let before=model.sentFrames,clock=ContinuousClock.now
        try await Task.sleep(for:.seconds(2))
        let duration=clock.duration(to:.now).secondsDouble,frames=model.sentFrames-before
        print("AUDIO_CADENCE frames=\(frames) seconds=\(duration) measuredHz=\(Double(frames)/duration) target=25")
        guard frames>=45,frames<=55 else{throw ProtocolError("Audio stream did not maintain the 25 Hz target")}
        print("AUDIO_RECOVERY_TEST_PASS · physical Mac sleep was not invoked")
    }catch{print("AUDIO_RECOVERY_TEST_FAIL \(error.localizedDescription)")}
    model.cancel();await model.waitForCleanup()
    do{_ = try await model.usb.exchange(Commands.brightness(0));_ = try await model.usb.exchange(Commands.off());let r=try await model.usb.exchange(Commands.getBrightness());print("AUDIO_RECOVERY_FINAL_OFF brightness=\(r[10])/255")}catch{print("FINAL_OFF_ERROR \(error.localizedDescription)")}
    await model.usb.close()
}

@MainActor private func runSystemDiagnostic() async {
    let previous=UserDefaults.standard.data(forKey:"lastPreset")
    defer{if let previous{UserDefaults.standard.set(previous,forKey:"lastPreset")}else{UserDefaults.standard.removeObject(forKey:"lastPreset")}}
    let model=AppModel(monitor:false)
    print("SYSTEM_TEST_BEGIN real providers → smoothing → custom frames → USB")
    for mode:Mode in [.volume,.battery,.temperature,.rainbow,.pulse]{
        model.preset.mode=mode;model.preset.rate=25;model.preset.brightness=0.25;model.preset.period=0.8
        model.apply()
        try? await Task.sleep(for:.seconds(2))
        let result=model.active && model.sentFrames>=30 ? "PASS" : "FAIL"
        print("SYSTEM_TEST_\(result) \(mode.rawValue) frames=\(model.sentFrames) input=\(model.inputLabel) RGB=\(model.preview.bytes) status=\(model.status)")
    }
    model.cancel()
    do{_ = try await model.usb.exchange(Commands.brightness(0));_ = try await model.usb.exchange(Commands.off());let reply=try await model.usb.exchange(Commands.getBrightness());print("SYSTEM_TEST_CLEANUP_OFF brightness=\(reply[10])/255")}catch{print("SYSTEM_TEST_CLEANUP_ERROR \(error.localizedDescription)")}
    await model.usb.close()
}

@MainActor private func runAudioDiagnostic() async {
    let audio=AudioMeter(),usb=RazerUSBActor()
    var player:Process?
    print("AUDIO_TEST_BEGIN bundle=local.minichroma.app · system audio only; no recording saved")
    do{
        try await audio.start()
        print("AUDIO_CAPTURE_STARTED")
        var preset=Preset(name:"Audio diagnostic");preset.mode = .audio;preset.brightness=0.25
        try await usb.apply(preset)
        var samples=0,frames=0;var maximum=0.0
        for tick in 0..<200 {
            if tick == 40{
                let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/afplay");p.arguments=["/System/Library/Sounds/Glass.aiff"];try p.run();player=p
                print("LOCAL_TEST_TONE_STARTED")
            }
            if let level=audio.current{
                samples += 1;maximum=max(maximum,level)
                if tick % 20 == 0{print("AUDIO_RMS \(String(format:"%.6f",level))")}
                _ = try await usb.exchange(Commands.frame(preset.color(time:Double(tick)/25,input:level) ?? .black));frames += 1
            }
            try await Task.sleep(for:.milliseconds(40))
        }
        guard samples>0,maximum>0.00001 else{throw ProtocolError("No nonzero captured audio: samples=\(samples) peakRMS=\(maximum)")}
        print("AUDIO_TEST_PASS samples=\(samples) USBframes=\(frames) peakRMS=\(maximum)")
    }catch{print("AUDIO_TEST_FAIL \(error.localizedDescription)")}
    if let player,player.isRunning{player.terminate()}
    await audio.stop()
    do{_ = try await usb.exchange(Commands.brightness(0));_ = try await usb.exchange(Commands.off());let reply=try await usb.exchange(Commands.getBrightness());print("AUDIO_TEST_CLEANUP_OFF brightness=\(reply[10])/255")}catch{print("AUDIO_TEST_CLEANUP_ERROR \(error.localizedDescription)")}
    await usb.close()
}

@MainActor final class AppModel:ObservableObject {
    @Published var preset=Preset(name:"Current")
    @Published var presets:[Preset]=[]
    @Published var status="Ready · lighting unchanged"
    @Published var inputLabel=""
    @Published var preview=RGB.black
    @Published var active=false
    @Published var sentFrames=0
    @Published var log="Diagnostics have not run.\n"
    @Published var testing=false
    @Published var autoRestore=UserDefaults.standard.bool(forKey:"autoRestore") {didSet{UserDefaults.standard.set(autoRestore,forKey:"autoRestore")}}
    @Published var login=SMAppService.mainApp.status == .enabled
    let usb:RazerUSBActor;let audio:any AudioCapturing;let cpu=CPUTemperature()
    let keyboardUSB=RazerUSBActor(profile:.keyboard)
    /// When on, the keyboard mirrors the mouse exactly. When off, it runs `keyboardPreset`.
    @Published var syncDevices=UserDefaults.standard.object(forKey:"syncDevices") as? Bool ?? true {didSet{UserDefaults.standard.set(syncDevices,forKey:"syncDevices")}}
    @Published var keyboardPreset=Preset(name:"Keyboard") {didSet{UserDefaults.standard.set(try? JSONEncoder().encode(keyboardPreset),forKey:"keyboardPreset")}}
    @Published var keyboardStatus="Keyboard not used yet"
    private var keyboardTask:Task<Void,Never>?
    /// Latest colour from the mouse's live loop. A separate task sends it to the keyboard,
    /// so keyboard busy-retries can never hold up the mouse's animation.
    private var keyboardColour:RGB?
    private var syncTask:Task<Void,Never>?
    private var task:Task<Void,Never>?
    private var cleanup:Task<Void,Never>?
    private var discovery:Task<Void,Never>?
    private var state=StreamState(rate:10)
    private var observers:[NSObjectProtocol]=[]
    private var sleeping=false
    private var desired=false
    private var effectiveRate=10.0
    private var colourWindow:NSWindow?
    init(usb:RazerUSBActor=RazerUSBActor(),audio:(any AudioCapturing)?=nil,monitor:Bool=true){
        self.usb=usb;self.audio=audio ?? AudioMeter()
        do{presets=try PresetRepository.load()}catch{status=error.localizedDescription}
        if let data=UserDefaults.standard.data(forKey:"lastPreset"),let last=try? JSONDecoder().decode(Preset.self,from:data){preset=last;preset.normalize()}
        if let data=UserDefaults.standard.data(forKey:"keyboardPreset"),var kp=try? JSONDecoder().decode(Preset.self,from:data){
            kp.normalize()
            // Older builds could save mouse-only effects here; fall back to static colour.
            if !kp.mode.keyboardSupported{kp.mode = .staticColor}
            keyboardPreset=kp
        }
        if monitor{upgradeStoredAudioRate();if let data=UserDefaults.standard.data(forKey:"lastPreset"),let saved=try? JSONDecoder().decode(Preset.self,from:data){preset=saved;preset.normalize()}}
        let center=NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.handleSleep()}})
        observers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.handleWake()}})
        guard monitor else{return}
        if autoRestore{apply()}
        discovery=Task{[weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(3))
                guard let self,!self.sleeping,!self.testing,!(self.active && self.preset.mode.live) else{continue}
                do{let reply=try await self.usb.exchange(Commands.firmwareVersion());if !self.active{self.status="Connected · firmware \(reply[8]).\(reply[9])";if self.desired{self.apply(recovering:true)}}}
                catch{self.active=false;self.status=error.localizedDescription;await self.usb.close()}
            }
        }
    }
    func cancel(){
        state.stop();task?.cancel();task=nil;active=false
        keyboardTask?.cancel();keyboardTask=nil;syncTask?.cancel();syncTask=nil;keyboardColour=nil
        let preceding=cleanup,audio=self.audio,usb=self.usb,keyboard=self.keyboardUSB
        cleanup=Task{await preceding?.value;await audio.stop();await usb.close();await keyboard.close()}
    }
    func handleSleep(){sleeping=true;cancel();status="Sleeping"}
    func handleWake(){sleeping=false;if desired{apply(recovering:true)}}
    func waitForCleanup() async{await cleanup?.value}
    func stop(){desired=false;cancel();status="Live updates stopped · last colour remains"}
    func off(){preset.mode = .off;apply()}
    func apply(recovering:Bool=false){
        guard !testing else{return}
        cancel();desired=true;sentFrames=0;preset.normalize();let p=preset
        UserDefaults.standard.set(try? JSONEncoder().encode(p),forKey:"lastPreset")
        if !recovering{effectiveRate=p.rate}
        state.start(rate:effectiveRate);let token=state.generation
        let pendingCleanup=cleanup
        task=Task{[weak self] in
            guard let self else{return}
            do{
                await pendingCleanup?.value
                guard state.accepts(token),!Task.isCancelled,!sleeping else{return}
                if p.mode == .temperature,await cpu.read()==nil{throw ProtocolError("CPU temperature unavailable: no validated AppleSMC M4 sensor")}
                if p.mode == .battery,SystemInputs.battery()==nil{throw ProtocolError("This Mac does not expose an internal battery")}
                if p.mode.usesAudio {
                    audio.configureBeat(p.mode == .beatAdapt ? p.beatConfiguration : nil)
                    do{try await audio.start()}catch{
                        let issue=(error as? AudioCaptureFailure) ?? AudioCaptureFailure.classify(error)
                        if issue.requiresUserAction{throw issue}
                        status="Audio unavailable · recovering; light off"
                    }
                }
                guard state.accepts(token),!Task.isCancelled else{return}
                try await usb.apply(p)
                guard state.accepts(token),!Task.isCancelled else{return}
                if syncDevices{
                    do{try await keyboardUSB.apply(p);keyboardStatus="Synced with mouse · \(p.mode.title)"}
                    catch{keyboardStatus="Keyboard: \(error.localizedDescription)"}
                    if p.mode.live{startSyncFrames(rate:p.rate)}
                }else{runKeyboard(keyboardPreset)}
                active=true;status=p.mode.live ? "Streaming · \(Int(state.rate)) Hz" : "On-mouse · \(p.mode.title)"
                if !p.mode.live{return}
                var color=RGB.black
                var envelope=AudioEnvelope()
                let start=ContinuousClock.now;var previous=start;var deadline=start;var consecutive=0
                var audioRecovery=AudioRecovery(now:0)
                while !Task.isCancelled,state.accepts(token),!sleeping {
                    let now=ContinuousClock.now
                    let elapsed=start.duration(to:now).secondsDouble,dt=previous.duration(to:now).secondsDouble;previous=now
                    var input:Double?;var mute=false
                    switch p.mode{
                    case .volume:if let v=SystemInputs.volume(){input=v.0;mute=v.1;inputLabel=v.1 ? "Muted" : "Volume \(Int(v.0*100))%"}else{inputLabel="Output volume unavailable for this audio device"}
                    case .battery:if let b=SystemInputs.battery(){input=b.0;inputLabel="Battery \(Int(b.0*100))%\(b.1 ? " · charging" : "")"}else{inputLabel="Battery unavailable"}
                    case .temperature:if let r=await cpu.read(){input=r.celsius;inputLabel="\(String(format:"%.1f",r.celsius)) °C · \(r.source)"}else{inputLabel="CPU sensor unavailable"}
                    case .audio,.beatAdapt:
                        if let failure=audio.failure,failure.requiresUserAction{throw failure}
                        input=audio.current
                        // A healthy tap may have no callbacks during silence: do not reauthorize it.
                        if !audio.needsRestart{_ = audioRecovery.shouldRestart(now:elapsed,hasSample:true,failed:false)}
                        if audio.needsRestart && audioRecovery.shouldRestart(now:elapsed,hasSample:false,failed:true){
                            _ = try await usb.exchange(Commands.frame(.black));preview = .black;color = .black
                            status="Restarting audio capture (\(audioRecovery.attempts)/5)"
                            await audio.stop()
                            guard state.accepts(token),!Task.isCancelled,!sleeping else{return}
                            do{try await audio.start()}catch{
                                let failure=(error as? AudioCaptureFailure) ?? AudioCaptureFailure.classify(error)
                                if failure.requiresUserAction{throw failure}
                                status="Audio interrupted · retrying"
                            }
                            guard state.accepts(token),!Task.isCancelled,!sleeping else{return}
                            audioRecovery.didRestart(now:start.duration(to:.now).secondsDouble)
                            input=audio.current
                        }
                        inputLabel=input == nil ? (audioRecovery.exhausted ? "Audio unavailable · Apply or wake to retry" : "Audio unavailable · recovering; light off") : "Audio RMS \(String(format:"%.3f",input!))"
                    default:inputLabel="Custom animation"
                    }
                    guard let target=p.color(time:elapsed,input:input,muted:mute) else{status=inputLabel;try await Task.sleep(for:.milliseconds(200));continue}
                    // Audio smooths scalar energy before mapping hue, and renders on every frame.
                    // Brief gaps fade smoothly; silence still reaches exact black within a bound.
                    if p.mode == .beatAdapt{
                        if let beat=audio.beat{
                            color=BeatRenderer.color(snapshot:beat.snapshot,age:beat.age,colour:p.primary,brightness:p.brightness,configuration:p.beatConfiguration,palette:(p.beatMulticolour ?? true) ? p.beatPalette : nil)
                            let rhythm=beat.bpm.map{String(format:"%.0f BPM · confidence %.0f%%",$0,beat.snapshot.confidence*100)} ?? "Listening for rhythm"
                            let learning = p.beatConfiguration.adaptive ? (beat.snapshot.learnedTemplates>0 ? "\(beat.snapshot.learnedTemplates) percussion sounds learned" : "Learning percussion") : "Learning off"
                            inputLabel=rhythm+" · "+learning
                        }else{color = .black;inputLabel="Listening for percussion · no tempo lock"}
                    }else{color = p.mode == .audio ? envelope.color(rms:input,preset:p,dt:dt) : color.smoothed(to:target,dt:dt,tau:p.smoothing)}
                    guard state.accepts(token),!Task.isCancelled else{break}
                    do{
                        _=try await usb.exchange(Commands.frame(color))
                        if syncDevices{keyboardColour=color}
                        guard state.accepts(token),!Task.isCancelled else{return}
                        consecutive=0;state.succeeded();sentFrames += 1;preview=color;status=p.mode.usesAudio && input == nil ? inputLabel : "Streaming · \(Int(state.rate)) Hz"
                    }catch{
                        guard state.accepts(token),!Task.isCancelled else{return}
                        consecutive += 1;state.failed();status="\(error.localizedDescription) · retrying at \(Int(state.rate)) Hz"
                        effectiveRate=state.rate
                        if consecutive>=3{throw error}
                        try await Task.sleep(for:.milliseconds(100))
                    }
                    deadline=deadline.advanced(by:.seconds(1/state.rate))
                    if deadline < .now{deadline=ContinuousClock.now}
                    try await ContinuousClock().sleep(until:deadline)
                }
            }catch is CancellationError {}catch{
                guard state.accepts(token) else{return}
                if p.mode.usesAudio{
                    _ = try? await usb.exchange(Commands.frame(.black))
                    guard state.accepts(token)else{return}
                    preview = .black
                }
                // Reconnect is bounded by the 3-second discovery timer.
                if p.mode == .temperature || p.mode == .battery || (error as? AudioCaptureFailure)?.requiresUserAction == true{desired=false}
                cancel();status=error.localizedDescription
            }
        }
    }
    /// Runs the keyboard's own preset. Audio effects stay on the mouse; use sync for those.
    func runKeyboard(_ kp:Preset){
        keyboardTask?.cancel()
        var kp=kp;kp.normalize()
        guard kp.mode.keyboardSupported else{
            keyboardTask=Task{[weak self] in try? await self?.keyboardUSB.apply(kp)}
            keyboardStatus="\(kp.mode.title) is not available on the keyboard; keyboard turned off"
            return
        }
        keyboardTask=Task{[weak self] in
            guard let self else{return}
            do{
                try await self.keyboardUSB.apply(kp)
                self.keyboardStatus=kp.mode.live ? "Keyboard streaming · \(kp.mode.title)" : "Keyboard · \(kp.mode.title)"
                guard kp.mode.live else{return}
                if kp.mode.usesAudio{self.keyboardStatus="Audio effects run on the mouse only · turn sync on to mirror them";return}
                let start=ContinuousClock.now;var previous=start;var color=RGB.black
                while !Task.isCancelled{
                    let now=ContinuousClock.now
                    let elapsed=start.duration(to:now).secondsDouble,dt=previous.duration(to:now).secondsDouble;previous=now
                    var input:Double?;var mute=false
                    switch kp.mode{
                    case .volume:if let v=SystemInputs.volume(){input=v.0;mute=v.1}
                    case .battery:if let b=SystemInputs.battery(){input=b.0}
                    case .temperature:if let r=await self.cpu.read(){input=r.celsius}
                    default:break
                    }
                    if let target=kp.color(time:elapsed,input:input,muted:mute){color=color.smoothed(to:target,dt:dt,tau:kp.smoothing)}
                    try await self.keyboardUSB.show(color)
                    try await Task.sleep(for:.milliseconds(max(20,Int(1000/max(1,kp.rate)))))
                }
            }catch is CancellationError{}
            catch{self.keyboardStatus="Keyboard: \(error.localizedDescription)"}
        }
    }
    /// Sends the mouse's latest colour to the keyboard at its own pace, independent of the mouse loop.
    func startSyncFrames(rate:Double){
        syncTask?.cancel()
        let interval=max(20,Int(1000/max(1,rate)))
        syncTask=Task{[weak self] in
            while !Task.isCancelled{
                guard let self else{return}
                if let colour=self.keyboardColour{
                    do{try await self.keyboardUSB.show(colour)}
                    catch{self.keyboardStatus="Keyboard: \(error.localizedDescription)"}
                }
                try? await Task.sleep(for:.milliseconds(interval))
            }
        }
    }
    /// Sync changed: restart the lighting so the keyboard follows the new choice.
    func syncChanged(){if desired{apply()}}
    /// Keyboard preset changed while running independently: restart only the keyboard.
    func keyboardChanged(){if desired && !syncDevices{runKeyboard(keyboardPreset)}}
    func save(){var p=preset;p.normalize();if let i=presets.firstIndex(where:{$0.id==p.id}){presets[i]=p}else{presets.append(p)};persist()}
    func showColourEditor(target:PresetColourTarget = .primary){
        if colourWindow == nil{
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:440,height:340),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.center();colourWindow=window
        }
        colourWindow?.title="MiniChroma · \(target.title)"
        colourWindow?.contentViewController=NSHostingController(rootView:ColourEditorView(model:self,target:target))
        colourWindow?.collectionBehavior = [.moveToActiveSpace]
        NSApplication.shared.activate(ignoringOtherApps:true)
        colourWindow?.makeKeyAndOrderFront(nil)
    }
    func duplicate(){preset.id=UUID();preset.name += " copy";save()}
    func delete(){presets.removeAll{$0.id==preset.id};persist();preset.id=UUID()}
    private func persist(){do{try PresetRepository.save(presets)}catch{status=error.localizedDescription}}
    func setLogin(_ value:Bool){do{if value{try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()};login=SMAppService.mainApp.status == .enabled}catch{status="Login item: \(error.localizedDescription)";login=SMAppService.mainApp.status == .enabled}}
    func readDevice(){Task{do{let r=try await usb.exchange(Commands.firmwareVersion());log += "1532:008C · interface 0 · firmware \(r[8]).\(r[9]) · validated reply\n"}catch{log += "ERROR \(error.localizedDescription)\n"}}}
    func diagnostic(){
        cancel();desired=false;testing=true;state.start(rate:5);let token=state.generation;log += "Testing firmware command acknowledgements and custom streaming. Lights will turn off afterward.\n"
        let pendingCleanup=cleanup
        task=Task{[weak self] in
            guard let self else{return}
            do{
                await pendingCleanup?.value
                guard state.accepts(token),!Task.isCancelled,!sleeping else{return}
                for mode in Mode.allCases.filter({!$0.live}){try Task.checkCancellation();var p=Preset(name:"Test");p.mode=mode;p.brightness=0.3;try await usb.apply(p);log += "ACK \(mode.title) (visual confirmation still required)\n";try await Task.sleep(for:.milliseconds(500))}
                for rate in [5.0,10,15,20,25]{
                    try await usb.apply({var p=Preset(name:"Test");p.mode = .rainbow;p.brightness=0.3;return p}())
                    let start=ContinuousClock.now;var count=0
                    while start.duration(to:.now) < .seconds(5){let now=ContinuousClock.now;_ = try await usb.exchange(Commands.frame(.hue(Double(count)/rate/4).mixed(.black,0.7)));count += 1;try await ContinuousClock().sleep(until:now.advanced(by:.seconds(1/rate)))}
                    log += "PASS \(Int(rate)) Hz · \(count) frames · 5 seconds (short check only)\n"
                }
            }catch{log += "\(error.localizedDescription)\n"}
            if state.accepts(token),!sleeping{
                do{_ = try await usb.exchange(Commands.off());log += "OFF acknowledged\n";status="Diagnostics finished · light off"}catch{log += "OFF failed: \(error.localizedDescription)\n"}
                active=false;await usb.close()
            }
            testing=false
        }
    }
    func quit(){desired=false;cancel();let pending=cleanup;Task{await pending?.value;if testing{_ = try? await usb.exchange(Commands.off())};await usb.close();NSApplication.shared.terminate(nil)}}
}
extension Duration{var secondsDouble:Double{Double(components.seconds)+Double(components.attoseconds)/1e18}}

struct ControlView:View{
    @ObservedObject var model:AppModel
    @Environment(\.openWindow) private var openWindow
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            HStack{Image(systemName:"computermouse.fill").foregroundStyle(.green);Text("MiniChroma").font(.headline);Spacer();Circle().fill(Color(red:model.preview.r,green:model.preview.g,blue:model.preview.b)).frame(width:20,height:20)}
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Picker("Effect",selection:$model.preset.mode){Section("On-mouse effects"){ForEach(Mode.allCases.filter{!$0.live}){Text($0.title).tag($0)}};Section("Live Mac effects"){ForEach(Mode.allCases.filter{$0.live}){Text($0.title+($0 == .temperature ? " · experimental SMC" : "")).tag($0)}}}.onChange(of:model.preset.mode){_,mode in if mode.usesAudio{model.preset.rate=25}}
            Text(model.preset.mode.live ? "Mac generates and streams colours while MiniChroma runs." : "The mouse runs this effect after one command.").font(.caption).foregroundStyle(.secondary)
            if [.staticColor,.reactive,.breathSingle,.breathDual,.pulse].contains(model.preset.mode){colourButton(model.preset.mode == .beatAdapt ? "Flash colour" : "Primary colour",value:model.preset.primary,target:.primary)}
            if [.breathDual,.pulse].contains(model.preset.mode){colourButton("Second colour",value:model.preset.secondary,target:.secondary)}
            if model.preset.mode == .audio{Text("Quiet → green · loud → red · silence → off").font(.caption)}
            if model.preset.mode == .beatAdapt{
                Toggle("Separate percussion colours",isOn:Binding(get:{model.preset.beatMulticolour ?? true},set:{model.preset.beatMulticolour=$0}))
                if model.preset.beatMulticolour ?? true{
                    colourButton("Bass / kick",value:model.preset.beatPalette.kick,target:.kick)
                    colourButton("Snare",value:model.preset.beatPalette.snare,target:.snare)
                    colourButton("High percussion",value:model.preset.beatPalette.hat,target:.hat)
                }else{colourButton("Flash colour",value:model.preset.primary,target:.primary)}
                Toggle("Learn recurring percussion",isOn:Binding(get:{model.preset.beatAdaptive ?? true},set:{model.preset.beatAdaptive=$0}))
                Toggle("Percussion focus",isOn:Binding(get:{model.preset.beatPercussionFocus ?? true},set:{model.preset.beatPercussionFocus=$0}))
                Text("Conservative transient classification, not isolated instruments. Focus rejects uncertain harmonic or slow attacks; some vocals may still trigger.").font(.caption).foregroundStyle(.secondary)
                slider("Beat sensitivity",value:Binding(get:{model.preset.beatSensitivity ?? 1},set:{model.preset.beatSensitivity=$0}),range:0.3...3)
                Text("Detail adds smaller high-percussion flashes; it never adds metronome beats.").font(.caption).foregroundStyle(.secondary)
                slider("Steady ↔ detailed",value:Binding(get:{model.preset.beatDetail ?? 0.5},set:{model.preset.beatDetail=$0}),range:0...1)
                slider("Pulse decay sec",value:Binding(get:{model.preset.beatDecay ?? 0.18},set:{model.preset.beatDecay=$0}),range:0.06...0.5)
            }
            if model.preset.mode == .reactive{Picker("Reactive speed",selection:$model.preset.reactiveSpeed){ForEach(1...4,id:\.self){Text("\($0)").tag($0)}}}
            if [.rainbow,.pulse].contains(model.preset.mode){slider("Cycle seconds",value:$model.preset.period,range:0.2...30)}
            if model.preset.mode.live{slider("Updates / second",value:$model.preset.rate,range:1...30);slider("Smoothing seconds",value:$model.preset.smoothing,range:0...2)}
            slider("Brightness",value:$model.preset.brightness,range:0...1)
            if !model.inputLabel.isEmpty,model.preset.mode.live{Text(model.inputLabel).font(.caption)}
            HStack{Button("Apply"){model.apply()}.buttonStyle(.borderedProminent).disabled(model.testing);Button("Stop"){model.stop()}.disabled(model.testing);Button("Light off"){model.off()}.disabled(model.testing)}
            Divider()
            Toggle("Sync keyboard with mouse",isOn:$model.syncDevices).onChange(of:model.syncDevices){_,_ in model.syncChanged()}
            if model.syncDevices{Text("Keyboard mirrors the mouse: same effect, colours and brightness.").font(.caption).foregroundStyle(.secondary)}
            else{
                Text("Keyboard runs its own effect. Audio effects stay on the mouse.").font(.caption).foregroundStyle(.secondary)
                Picker("Keyboard effect",selection:$model.keyboardPreset.mode){ForEach(Mode.allCases.filter{$0.keyboardSupported}){Text($0.title).tag($0)}}.onChange(of:model.keyboardPreset.mode){_,_ in model.keyboardChanged()}
                slider("Keyboard brightness",value:$model.keyboardPreset.brightness,range:0...1).onChange(of:model.keyboardPreset.brightness){_,_ in model.keyboardChanged()}
            }
            Text(model.keyboardStatus).font(.caption).foregroundStyle(.secondary)
            Divider()
            Menu("Presets"){ForEach(model.presets){p in Button(p.name){model.preset=p;model.apply()}};Button("Save current preset…"){openWindow(id:"settings")}}.disabled(model.testing)
            HStack{Button("Settings"){openWindow(id:"settings")};Button("Diagnostics"){openWindow(id:"diagnostics")};Spacer();Button("Quit"){model.quit()}}
        }
    }
    func colourButton(_ title:String,value:RGB,target:PresetColourTarget)->some View{Button{model.showColourEditor(target:target)}label:{HStack{Text(title);Spacer();RoundedRectangle(cornerRadius:4).fill(Color(red:value.r,green:value.g,blue:value.b)).frame(width:42,height:20);Text("Edit…")}}}
    func slider(_ title:String,value:Binding<Double>,range:ClosedRange<Double>)->some View{HStack{Text(title).font(.caption).frame(width:120,alignment:.leading);Slider(value:value,in:range);Text(String(format:"%.2g",value.wrappedValue)).font(.caption.monospacedDigit()).frame(width:36)}}
}
struct SettingsView:View{
    @ObservedObject var model:AppModel
    var body:some View{Form{
        Text("MiniChroma Settings").font(.title2)
        HStack{Button("Edit primary colour…"){model.showColourEditor()};Button("Edit second colour…"){model.showColourEditor(target:.secondary)}}
        Toggle("Launch at login",isOn:Binding(get:{model.login},set:{model.setLogin($0)}))
        Toggle("Restore last effect when app starts",isOn:$model.autoRestore)
        TextField("Preset name",text:$model.preset.name)
        HStack{Button("Save / update"){model.save()};Button("Duplicate"){model.duplicate()};Button("Delete saved preset"){model.delete()}}
        Slider(value:$model.preset.midpoint,in:0.05...0.95){Text("Yellow threshold \(Int(model.preset.midpoint*100))%")}
        Slider(value:$model.preset.gain,in:1...30){Text("Audio gain \(Int(model.preset.gain))×")}
        Slider(value:$model.preset.noiseGate,in:0...0.1){Text("Audio noise gate \(String(format:"%.3f",model.preset.noiseGate))")}
        Text("Audio maps digital RMS green through yellow to red. The noise gate turns silence fully off. CoreAudio captures system audio only: no screen, display or microphone access. macOS may ask for System Audio Recording permission.").font(.caption)
        Text("CPU temperature uses a read-only experimental AppleSMC backend, validated on this M4 Mac. macOS updates may change this private sensor interface. Battery is available only on Macs with an internal battery.").font(.caption).foregroundStyle(.secondary)
        HStack{Text("CPU cool °C");TextField("Cool",value:$model.preset.cool,format:.number);Text("Hot °C");TextField("Hot",value:$model.preset.hot,format:.number)}
        Text(model.status).font(.caption)
    }}
}

struct ColourEditorView:View{
    @ObservedObject var model:AppModel
    let target:PresetColourTarget
    private var colour:RGB{target.colour(in:model.preset)}
    private var hex:String{String(format:"#%02X%02X%02X",colour.bytes[0],colour.bytes[1],colour.bytes[2])}
    private func set(_ value:RGB){target.set(value,in:&model.preset)}
    private func channel(_ index:Int)->Binding<Double>{Binding(get:{[colour.r,colour.g,colour.b][index]},set:{value in var c=colour;if index==0{c.r=value}else if index==1{c.g=value}else{c.b=value};set(c)})}
    var body:some View{
        VStack(alignment:.leading,spacing:16){
            Text(target.title).font(.title2)
            HStack{RoundedRectangle(cornerRadius:10).fill(Color(red:colour.r,green:colour.g,blue:colour.b)).overlay(RoundedRectangle(cornerRadius:10).stroke(.secondary)).frame(width:110,height:65);Text(hex).font(.title.monospaced()).accessibilityIdentifier("colour-hex")}
            ForEach(0..<3,id:\.self){i in HStack{Text(["Red","Green","Blue"][i]).frame(width:50,alignment:.leading);Slider(value:channel(i),in:0...1).accessibilityLabel(["Red","Green","Blue"][i]);Text("\(colour.bytes[i])").monospacedDigit().frame(width:30)}}
            HStack{ForEach(Array([("Red",RGB(1,0,0)),("Green",RGB(0,1,0)),("Blue",RGB(0,0,1)),("Yellow",RGB(1,1,0)),("White",RGB.white),("Black",RGB.black)].enumerated()),id:\.offset){_,item in Button(item.0){set(item.1)}}}
            Text("Changes update the selected preset. Click Apply to send its effect to the mouse.").font(.caption).foregroundStyle(.secondary)
            HStack{Spacer();Button("Apply effect"){model.apply()}.buttonStyle(.borderedProminent).disabled(model.testing)}
        }.padding(22).frame(width:440)
    }
}
struct DiagnosticsView:View{
    @ObservedObject var model:AppModel
    var body:some View{VStack(alignment:.leading,spacing:14){
        Text("Hardware Diagnostics").font(.title2)
        Text("Read checks metadata without changing lighting. Run light tests cycles firmware effects and tests 5–25 Hz briefly, then turns the logo off. A successful reply confirms command acceptance; inspect the logo and mouse movement to confirm behavior.").font(.callout)
        HStack{Button("Read device"){model.readDevice()}.disabled(model.testing);Button("Run light tests"){model.diagnostic()}.disabled(model.testing);Button("Copy report"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(model.log,forType:.string)}}
        ScrollView{Text(model.log).font(.system(.caption,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)}.background(.quaternary.opacity(0.2))
        Text("25 Hz remains a preferred rate until a five-minute soak and your confirmation of normal mouse input. Normal default is 10 Hz.").font(.caption).foregroundStyle(.secondary)
    }}
}
