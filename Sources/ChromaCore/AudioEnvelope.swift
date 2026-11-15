import Foundation

/// A time-based scalar envelope, evaluated on every RGB frame rather than only on audio callbacks.
public struct AudioEnvelope:Sendable{
    public private(set) var level=0.0
    private var visibility=0.0,silence=0.0,silenceStartVisibility=0.0
    public init(){}
    public mutating func color(rms:Double?,preset:Preset,dt:Double)->RGB{
        let elapsed=max(0,dt.isFinite ? dt : 0)
        let target=preset.normalizedAudioLevel(rms)
        let smoothing=preset.smoothing.isFinite ? preset.smoothing : 0.15
        let attack=max(0.025,min(0.06,smoothing*0.35))
        let release=max(0.06,min(0.18,smoothing))
        if target>0{
            silence=0
            let tau=target>level ? attack : release
            level += (target-level)*(1-exp(-elapsed/tau))
            visibility += (1-visibility)*(1-exp(-elapsed/0.035))
        }else{
            if silence==0{silenceStartVisibility=visibility}
            silence += elapsed
            // A short dropout fades over three 25 Hz frames, then is exactly off.
            if silence>=0.12-0.0000001{level=0;visibility=0;return .black}
            level *= exp(-elapsed/release)
            let progress=min(1,max(0,(silence-0.02)/0.10))
            let ease=progress*progress*(3-2*progress)
            visibility=silenceStartVisibility*(1-ease)
        }
        return .black.mixed(.volume(level,midpoint:preset.midpoint),visibility*preset.brightness)
    }
}
