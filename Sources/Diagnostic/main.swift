import Foundation
import ChromaCore

let usb=RazerUSBActor()
let args=CommandLine.arguments
do {
    let action=args.dropFirst().first ?? "read"
    if action == "read" {
        let reply=try await usb.exchange(Commands.firmwareVersion())
        print("1532:008C · interface 0 · firmware \(reply[8]).\(reply[9]) · validated reply")
    } else if action == "temperature" {
        let cpu=CPUTemperature()
        print(await cpu.diagnostics().joined(separator:"\n"))
        for _ in 0..<5{
            guard let reading=await cpu.read() else{throw ProtocolError("No validated M4 CPU temperature sensor available")}
            print("CPU \(reading.celsius) °C · \(reading.source)")
            try await Task.sleep(for:.seconds(1))
        }
    } else if action == "stream" {
        let rate=min(30,max(1,Double(args.count>2 ? args[2] : "10") ?? 10))
        let seconds=min(600,max(1,Double(args.count>3 ? args[3] : "10") ?? 10))
        var p=Preset(name:"diagnostic");p.mode = .rainbow;p.brightness=0.35
        try await usb.apply(p)
        let start=ContinuousClock.now;var count=0;var maxLatency=0.0;var deadline=start
        while start.duration(to:.now) < .seconds(seconds) {
            let frameStart=ContinuousClock.now
            let elapsed=Double(start.duration(to:frameStart).components.seconds)+Double(start.duration(to:frameStart).components.attoseconds)/1e18
            _ = try await usb.exchange(Commands.frame(RGB.hue(elapsed/4).mixed(.black,0.65)))
            maxLatency=max(maxLatency,Double(frameStart.duration(to:.now).components.attoseconds)/1e18)
            count += 1
            deadline=deadline.advanced(by:.seconds(1/rate))
            if deadline < .now { deadline=ContinuousClock.now }
            try await ContinuousClock().sleep(until:deadline)
        }
        _ = try await usb.exchange(Commands.off())
        print("PASS frames=\(count) rate=\(rate)Hz duration=\(seconds)s maxLatency=\(maxLatency)s errors=0; final OFF acknowledged")
    } else if action == "effects" {
        for mode in Mode.allCases.filter({ !$0.live }) {
            var p=Preset(name:"test");p.mode=mode;p.brightness=0.35
            try await usb.apply(p);print("ACK \(mode.rawValue)")
            try await Task.sleep(for:.seconds(1))
        }
        _ = try await usb.exchange(Commands.off());print("OFF acknowledged")
    } else {
        guard let mode=Mode(rawValue:action), !mode.live else { throw ProtocolError("Usage: read | off | effects | stream [Hz] [seconds] | staticColor | spectrum | reactive | breathSingle | breathDual | breathRandom") }
        if mode == .off{_ = try await usb.exchange(Commands.brightness(0))}
        _ = try await usb.exchange(Commands.firmware(mode));print("\(mode.title) acknowledged")
        if mode == .off{let response=try await usb.exchange(Commands.getBrightness());guard response[10] == 0 else{throw ProtocolError("Off accepted but brightness readback was not zero")};print("Brightness readback: 0/255")}
    }
    await usb.close()
} catch {
    fputs("ERROR: \(error.localizedDescription)\n",stderr)
    if let _ = try? await usb.exchange(Commands.off()) { fputs("Cleanup OFF acknowledged\n",stderr) }
    await usb.close();exit(1)
}
