import SwiftUI
import AppKit
import ServiceManagement
import ChromaCore

@main struct MiniChromaApp: App {
    @StateObject private var model=AppModel(monitor: !CommandLine.arguments.contains("--preview") && !CommandLine.arguments.contains("--audio-test") && !CommandLine.arguments.contains("--system-test"))
    init(){
        if CommandLine.arguments.contains("--audio-test"){
            setbuf(stdout,nil)
            Task{@MainActor in await runAudioDiagnostic();NSApplication.shared.terminate(nil)}
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
    let usb:RazerUSBActor;let audio=AudioMeter();let cpu=CPUTemperature()
    private var task:Task<Void,Never>?
    private var discovery:Task<Void,Never>?
    private var state=StreamState(rate:10)
    private var observers:[NSObjectProtocol]=[]
    private var sleeping=false
    private var desired=false
    private var effectiveRate=10.0
    init(usb:RazerUSBActor=RazerUSBActor(),monitor:Bool=true){
        self.usb=usb
        do{presets=try PresetRepository.load()}catch{status=error.localizedDescription}
        if let data=UserDefaults.standard.data(forKey:"lastPreset"),let last=try? JSONDecoder().decode(Preset.self,from:data){preset=last;preset.normalize()}
        let center=NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.sleeping=true;self?.cancel();self?.status="Sleeping";await self?.usb.close()}})
        observers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in guard let self else{return};self.sleeping=false;if self.desired{self.apply()}}})
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
    func cancel(){state.stop();task?.cancel();task=nil;active=false;Task{await audio.stop()}}
    func stop(){desired=false;cancel();status="Live updates stopped · last colour remains";Task{await usb.close()}}
    func off(){preset.mode = .off;apply()}
    func apply(recovering:Bool=false){
        guard !testing else{return}
        cancel();desired=true;sentFrames=0;preset.normalize();let p=preset
        UserDefaults.standard.set(try? JSONEncoder().encode(p),forKey:"lastPreset")
        if !recovering{effectiveRate=p.rate}
        state.start(rate:effectiveRate);let token=state.generation
        task=Task{[weak self] in
            guard let self else{return}
            do{
                if p.mode == .temperature,await cpu.read()==nil{throw ProtocolError("CPU temperature unavailable: no validated AppleSMC M4 sensor")}
                if p.mode == .battery,SystemInputs.battery()==nil{throw ProtocolError("This Mac does not expose an internal battery")}
                if p.mode == .audio {try await audio.start()}
                guard state.accepts(token),!Task.isCancelled else{return}
                try await usb.apply(p)
                guard state.accepts(token),!Task.isCancelled else{return}
                active=true;status=p.mode.live ? "Streaming · \(Int(state.rate)) Hz" : "On-mouse · \(p.mode.title)"
                if !p.mode.live{return}
                var color=RGB.black
                let start=ContinuousClock.now;var previous=start;var deadline=start;var consecutive=0
                while !Task.isCancelled,state.accepts(token),!sleeping {
                    let now=ContinuousClock.now
                    let elapsed=start.duration(to:now).secondsDouble,dt=previous.duration(to:now).secondsDouble;previous=now
                    var input:Double?;var mute=false
                    switch p.mode{
                    case .volume:if let v=SystemInputs.volume(){input=v.0;mute=v.1;inputLabel=v.1 ? "Muted" : "Volume \(Int(v.0*100))%"}else{inputLabel="Output volume unavailable for this audio device"}
                    case .battery:if let b=SystemInputs.battery(){input=b.0;inputLabel="Battery \(Int(b.0*100))%\(b.1 ? " · charging" : "")"}else{inputLabel="Battery unavailable"}
                    case .temperature:if let r=await cpu.read(){input=r.celsius;inputLabel="\(String(format:"%.1f",r.celsius)) °C · \(r.source)"}else{inputLabel="CPU sensor unavailable"}
                    case .audio:input=audio.current;inputLabel=input == nil ? "Waiting for system audio samples" : "Audio level \(String(format:"%.3f",input!))"
                    default:inputLabel="Custom animation"
                    }
                    guard let target=p.color(time:elapsed,input:input,muted:mute) else{status=inputLabel;try await Task.sleep(for:.milliseconds(200));continue}
                    color=color.smoothed(to:target,dt:dt,tau:p.smoothing)
                    guard state.accepts(token),!Task.isCancelled else{break}
                    do{
                        _=try await usb.exchange(Commands.frame(color))
                        guard state.accepts(token),!Task.isCancelled else{return}
                        consecutive=0;state.succeeded();sentFrames += 1;preview=color;status="Streaming · \(Int(state.rate)) Hz"
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
                status=error.localizedDescription;active=false;await usb.close();await audio.stop()
                // Reconnect is bounded by the 3-second discovery timer.
                if p.mode == .temperature || p.mode == .battery || p.mode == .audio{desired=false}
            }
        }
    }
    func save(){var p=preset;p.normalize();if let i=presets.firstIndex(where:{$0.id==p.id}){presets[i]=p}else{presets.append(p)};persist()}
    func duplicate(){preset.id=UUID();preset.name += " copy";save()}
    func delete(){presets.removeAll{$0.id==preset.id};persist();preset.id=UUID()}
    private func persist(){do{try PresetRepository.save(presets)}catch{status=error.localizedDescription}}
    func setLogin(_ value:Bool){do{if value{try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()};login=SMAppService.mainApp.status == .enabled}catch{status="Login item: \(error.localizedDescription)";login=SMAppService.mainApp.status == .enabled}}
    func readDevice(){Task{do{let r=try await usb.exchange(Commands.firmwareVersion());log += "1532:008C · interface 0 · firmware \(r[8]).\(r[9]) · validated reply\n"}catch{log += "ERROR \(error.localizedDescription)\n"}}}
    func diagnostic(){
        cancel();desired=false;testing=true;state.start(rate:5);let token=state.generation;log += "Testing firmware command acknowledgements and custom streaming. Lights will turn off afterward.\n"
        task=Task{[weak self] in
            guard let self else{return}
            do{
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
    func quit(){desired=false;cancel();Task{if testing{_ = try? await usb.exchange(Commands.off())};await usb.close();NSApplication.shared.terminate(nil)}}
}
extension Duration{var secondsDouble:Double{Double(components.seconds)+Double(components.attoseconds)/1e18}}

struct ControlView:View{
    @ObservedObject var model:AppModel
    @Environment(\.openWindow) private var openWindow
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            HStack{Image(systemName:"computermouse.fill").foregroundStyle(.green);Text("MiniChroma").font(.headline);Spacer();Circle().fill(Color(red:model.preview.r,green:model.preview.g,blue:model.preview.b)).frame(width:20,height:20)}
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Picker("Effect",selection:$model.preset.mode){Section("On-mouse effects"){ForEach(Mode.allCases.filter{!$0.live}){Text($0.title).tag($0)}};Section("Live Mac effects"){ForEach(Mode.allCases.filter{$0.live}){Text($0.title+($0 == .temperature ? " · experimental SMC" : "")).tag($0)}}}
            Text(model.preset.mode.live ? "Mac generates and streams colours while MiniChroma runs." : "The mouse runs this effect after one command.").font(.caption).foregroundStyle(.secondary)
            if [.staticColor,.reactive,.breathSingle,.breathDual,.pulse,.audio].contains(model.preset.mode){ColorPicker("Primary colour",selection:colorBinding(\.primary),supportsOpacity:false)}
            if [.breathDual,.pulse].contains(model.preset.mode){ColorPicker("Second colour",selection:colorBinding(\.secondary),supportsOpacity:false)}
            if model.preset.mode == .reactive{Picker("Reactive speed",selection:$model.preset.reactiveSpeed){ForEach(1...4,id:\.self){Text("\($0)").tag($0)}}}
            if [.rainbow,.pulse].contains(model.preset.mode){slider("Cycle seconds",value:$model.preset.period,range:0.2...30)}
            if model.preset.mode.live{slider("Updates / second",value:$model.preset.rate,range:1...30);slider("Smoothing seconds",value:$model.preset.smoothing,range:0...2)}
            slider("Brightness",value:$model.preset.brightness,range:0...1)
            if !model.inputLabel.isEmpty,model.preset.mode.live{Text(model.inputLabel).font(.caption)}
            HStack{Button("Apply"){model.apply()}.buttonStyle(.borderedProminent).disabled(model.testing);Button("Stop"){model.stop()}.disabled(model.testing);Button("Light off"){model.off()}.disabled(model.testing)}
            Divider()
            Menu("Presets"){ForEach(model.presets){p in Button(p.name){model.preset=p;model.apply()}};Button("Save current preset…"){openWindow(id:"settings")}}.disabled(model.testing)
            HStack{Button("Settings"){openWindow(id:"settings")};Button("Diagnostics"){openWindow(id:"diagnostics")};Spacer();Button("Quit"){model.quit()}}
        }
    }
    func colorBinding(_ path:WritableKeyPath<Preset,RGB>)->Binding<Color>{Binding(get:{let c=model.preset[keyPath:path];return Color(red:c.r,green:c.g,blue:c.b)},set:{let c=NSColor($0).usingColorSpace(.deviceRGB) ?? .green;model.preset[keyPath:path]=RGB(c.redComponent,c.greenComponent,c.blueComponent)})}
    func slider(_ title:String,value:Binding<Double>,range:ClosedRange<Double>)->some View{HStack{Text(title).font(.caption).frame(width:120,alignment:.leading);Slider(value:value,in:range);Text(String(format:"%.2g",value.wrappedValue)).font(.caption.monospacedDigit()).frame(width:36)}}
}
struct SettingsView:View{
    @ObservedObject var model:AppModel
    var body:some View{Form{
        Text("MiniChroma Settings").font(.title2)
        Toggle("Launch at login",isOn:Binding(get:{model.login},set:{model.setLogin($0)}))
        Toggle("Restore last effect when app starts",isOn:$model.autoRestore)
        TextField("Preset name",text:$model.preset.name)
        HStack{Button("Save / update"){model.save()};Button("Duplicate"){model.duplicate()};Button("Delete saved preset"){model.delete()}}
        Slider(value:$model.preset.midpoint,in:0.05...0.95){Text("Yellow threshold \(Int(model.preset.midpoint*100))%")}
        Slider(value:$model.preset.gain,in:1...30){Text("Audio gain \(Int(model.preset.gain))×")}
        Slider(value:$model.preset.noiseGate,in:0...0.1){Text("Audio noise gate \(String(format:"%.3f",model.preset.noiseGate))")}
        Text("Audio reactive uses macOS system audio capture. macOS may ask for Screen & System Audio Recording permission. No microphone or Accessibility permission is used.").font(.caption)
        Text("CPU temperature uses a read-only experimental AppleSMC backend, validated on this M4 Mac. macOS updates may change this private sensor interface. Battery is available only on Macs with an internal battery.").font(.caption).foregroundStyle(.secondary)
        HStack{Text("CPU cool °C");TextField("Cool",value:$model.preset.cool,format:.number);Text("Hot °C");TextField("Hot",value:$model.preset.hot,format:.number)}
        Text(model.status).font(.caption)
    }}
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
