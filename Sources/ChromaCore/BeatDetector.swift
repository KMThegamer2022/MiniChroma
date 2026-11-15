import Foundation

public struct BeatConfiguration:Sendable,Equatable{
    public var sensitivity:Double,detail:Double,decay:Double,gate:Double
    public var percussionFocus:Bool,adaptive:Bool
    public init(sensitivity:Double=1,detail:Double=0.5,decay:Double=0.18,gate:Double=0.006,percussionFocus:Bool=true,adaptive:Bool=true){
        self.adaptive=adaptive
        self.percussionFocus=percussionFocus
        self.sensitivity=min(3,max(0.3,sensitivity.isFinite ? sensitivity : 1))
        self.detail=min(1,max(0,detail.isFinite ? detail : 0.5))
        self.decay=min(0.5,max(0.06,decay.isFinite ? decay : 0.18))
        self.gate=min(0.1,max(0.0001,gate.isFinite ? gate : 0.006))
    }
}
public enum PercussionKind:String,Codable,Sendable{case kick,snare,hat}
public struct BeatPalette:Sendable,Equatable{
    public var kick:RGB,snare:RGB,hat:RGB
    public init(kick:RGB=RGB(1,0,0),snare:RGB=RGB(0,0,1),hat:RGB=RGB(1,1,0)){self.kick=kick;self.snare=snare;self.hat=hat}
}
public struct BeatSnapshot:Sendable{
    public var time=0.0,lastSignal = -Double.infinity,lastOnset = -Double.infinity
    public var lastMain = -Double.infinity,lastExtra = -Double.infinity
    public var phase=0.0,period=0.5,confidence=0.0,mainStrength=0.0,extraStrength=0.0
    public var mainCount=0,extraCount=0,kickCount=0,snareCount=0,hatCount=0
    public var lastKick = -Double.infinity,lastSnare = -Double.infinity,lastHat = -Double.infinity,hatStrength=0.0
    public var spectralFlatness=0.0
    public var learnedTemplates=0,learningTemplates=0
    public var bassLevel=0.0,midLevel=0.0,highLevel=0.0,bassFlux=0.0,highFlux=0.0,bassThreshold=0.0,highThreshold=0.0
    public var bpm:Double?{confidence>=0.62 && time-lastOnset<period*2 && time-lastSignal<max(0.65,period*1.5) ? 60/period : nil}
}

/// Streaming PCM analysis. A 64ms magnitude spectrum advances every 5ms.
/// The tracker uses corroborating onset intervals/phase; it never derives tempo from RGB-rate RMS.
public struct BeatDetector:Sendable{
    public private(set) var snapshot=BeatSnapshot()
    private let configuration:BeatConfiguration
    private var memory=PercussionMemory()
    private var spectrum=AttackSpectrum(),resamplePhase=0.0,antiAlias=0.0
    private var sampleRate=0.0,window=40,frames=0,sampleCount=0
    private var bassLP=0.0,dcLP=0.0,trebleLP=0.0
    private var bassSum=0.0,highSum=0.0,midSum=0.0,totalSum=0.0
    private var bassRing=[Double](repeating:0,count:4),highRing=[Double](repeating:0,count:4),totalRing=[Double](repeating:0,count:4),midRing=[Double](repeating:0,count:4),ringIndex=0
    private var meanBassFlux=0.0,meanHighFlux=0.0
    private var bassFluxDeviation=0.0,highFluxDeviation=0.0
    private var analysisLevel=0.0,pending:JointAttack?,lastCandidate = -Double.infinity
    private var previousRawHigh=0.0,fastHighAttack = -Double.infinity
    private var strongTimes:[Double]=[]
    public init(configuration:BeatConfiguration){self.configuration=configuration}
    public mutating func process(_ samples:[Float],sampleRate:Double){samples.withUnsafeBufferPointer{process($0,sampleRate:sampleRate)}}
    public mutating func process(_ samples:UnsafeBufferPointer<Float>,sampleRate rate:Double){
        guard rate.isFinite,rate>=4000 else{return}
        if sampleRate != rate{self=BeatDetector(configuration:configuration);sampleRate=rate;window=max(1,Int(rate*0.005))}
        let aliasA=1-exp(-2*Double.pi*min(3000,rate*0.4)/rate)
        let bassA=1-exp(-2*Double.pi*180/rate),dcA=1-exp(-2*Double.pi*25/rate),highA=1-exp(-2*Double.pi*min(1800,rate*0.4)/rate)
        for raw in samples{
            let x=raw.isFinite ? min(1,max(-1,Double(raw))) : 0
            antiAlias += aliasA*(x-antiAlias)
            resamplePhase += 8000/rate
            while resamplePhase>=1{spectrum.append(antiAlias);resamplePhase -= 1}
            bassLP += bassA*(x-bassLP);dcLP += dcA*(x-dcLP);trebleLP += highA*(x-trebleLP)
            let bass=bassLP-dcLP,high=x-trebleLP,mid=trebleLP-bassLP
            bassSum += bass*bass;highSum += high*high;midSum += mid*mid;totalSum += x*x
            frames += 1;sampleCount += 1
            if frames==window{analyzeWindow();frames=0;bassSum=0;highSum=0;midSum=0;totalSum=0}
        }
    }
    private mutating func analyzeWindow(){
        bassRing[ringIndex]=bassSum;highRing[ringIndex]=highSum;totalRing[ringIndex]=totalSum;midRing[ringIndex]=midSum;ringIndex=(ringIndex+1)%4
        let divisor=Double(window*4)
        let bass=sqrt(bassRing.reduce(0,+)/divisor),high=sqrt(highRing.reduce(0,+)/divisor),total=sqrt(totalRing.reduce(0,+)/divisor)
        let mid=sqrt(midRing.reduce(0,+)/divisor)
        let now=Double(sampleCount)/sampleRate;snapshot.time=now
        analysisLevel=max(total,analysisLevel*exp(-0.005/0.5))
        let analysisGain=min(32,max(1,0.10/max(0.0001,analysisLevel)))
        let rawHigh=sqrt(highSum/Double(window))
        if rawHigh-previousRawHigh>max(0.003/(configuration.sensitivity*analysisGain),previousRawHigh*0.75){fastHighAttack=now}
        previousRawHigh=rawHigh
        let spectral=spectrum.analyze()
        let bf=spectral.lowRise*analysisGain,hf=spectral.highRise*analysisGain
        let bassThreshold=max(0.003,max(meanBassFlux+3*bassFluxDeviation,spectral.low*analysisGain*0.018))/configuration.sensitivity
        let highThreshold=max(0.006,max(meanHighFlux+3*highFluxDeviation,spectral.high*analysisGain*0.018))/configuration.sensitivity
        snapshot.spectralFlatness=spectral.flatness
        snapshot.bassLevel=bass;snapshot.midLevel=mid;snapshot.highLevel=high
        snapshot.bassFlux=bf;snapshot.highFlux=hf;snapshot.bassThreshold=bassThreshold;snapshot.highThreshold=highThreshold
        let audible=total*analysisGain>configuration.gate
        if audible{snapshot.lastSignal=now}
        let attack = (bf>bassThreshold || hf>highThreshold) && audible
        if pending == nil,attack,now-lastCandidate>0.085{
            lastCandidate=now;pending=JointAttack(start:now)
        }
        if pending != nil{
            pending!.include(lowFlux:spectral.lowRise,midFlux:spectral.midRise,highFlux:spectral.highRise,fingerprint:spectral.fingerprint,spread:spectral.spread,lowCentroid:spectral.lowCentroid,low:bass,high:high,fastHigh:now-fastHighAttack<0.055,lowScore:bf/max(1e-8,bassThreshold),highScore:hf/max(1e-8,highThreshold),tailSpread:spectral.tailSpread)
            if now-pending!.start>=0.035-1e-9{
                let event=pending!;pending=nil
                if var decision=event.classify(focus:configuration.percussionFocus){
                    if configuration.adaptive,let known=memory.recognizedKind(features:event.fingerprint),decision.confidence<0.80{decision.kind=known}
                    let convincing=decision.confidence>=0.75 && max(event.lowScore,event.highScore)>1.25
                    let accepted = !configuration.adaptive || memory.accepts(kind:decision.kind,features:event.fingerprint,time:now,convincing:convincing,eligible:true)
                    if accepted{register(now:now,kind:decision.kind,strength:1)}
                }
            }
        }
        snapshot.learnedTemplates=memory.learnedCount;snapshot.learningTemplates=memory.learningCount
        bassFluxDeviation += 0.025*(abs(bf-meanBassFlux)-bassFluxDeviation)
        highFluxDeviation += 0.025*(abs(hf-meanHighFlux)-highFluxDeviation)
        meanBassFlux += 0.025*(bf-meanBassFlux);meanHighFlux += 0.025*(hf-meanHighFlux)
        if now-snapshot.lastSignal>max(0.65,snapshot.period*1.5){snapshot.confidence=0}
        if now-snapshot.lastSignal>2,memory.learnedCount+memory.learningCount>0{memory.reset();snapshot.learnedTemplates=0;snapshot.learningTemplates=0}
        if now-snapshot.lastSignal>max(1.2,snapshot.period*2.5),!strongTimes.isEmpty{
            strongTimes.removeAll();snapshot.confidence=0;snapshot.lastMain = -Double.infinity;snapshot.lastExtra = -Double.infinity
            pending=nil;lastCandidate = -Double.infinity
        }
    }
    private mutating func register(now:Double,kind:PercussionKind,strength:Double){
        let tempo=kind == .kick,strong=kind != .hat
        switch kind{
        case .kick:snapshot.lastKick=now;snapshot.kickCount += 1
        case .snare:snapshot.lastSnare=now;snapshot.snareCount += 1
        case .hat:snapshot.lastHat=now;snapshot.hatStrength=strength;snapshot.hatCount += 1
        }
        snapshot.lastOnset=now
        if tempo{
            strongTimes.append(now);if strongTimes.count>10{strongTimes.removeFirst()}
            updateTempo()
        }
        // Drum evidence drives the groove, even when the hit is off the inferred beat grid.
        if strong{
            snapshot.lastMain=now;snapshot.mainStrength=1;snapshot.mainCount += 1
            if tempo{snapshot.phase=now}
        }else{
            snapshot.lastExtra=now;snapshot.extraStrength=strength;snapshot.extraCount += 1
        }
    }
    private mutating func updateTempo(){
        guard strongTimes.count>=3 else{if let last=strongTimes.last{snapshot.phase=last};return}
        let intervals=zip(strongTimes.dropFirst(),strongTimes).map(-).suffix(8)
        let list=Array(intervals)
        var candidates:[Double]=[]
        for interval in list{for multiple in 1...4{let p=interval/Double(multiple);if (0.30...1.0).contains(p){candidates.append(p)}}}
        var bestPeriod=snapshot.period,bestScore=0.0,bestSupport=0.0
        for candidate in candidates{
            var score=0.0,support=0.0,total=0.0
            for (index,interval) in list.enumerated(){
                let weight=pow(0.72,Double(list.count-1-index)),multiple=max(1,(interval/candidate).rounded())
                let residual=abs(interval-multiple*candidate)
                let agreement=exp(-pow(residual/max(0.015,candidate*0.09),2))
                support += weight*agreement;score += weight*agreement/sqrt(multiple);total += weight
            }
            let normalized=score/max(0.001,total)
            if normalized>bestScore{bestScore=normalized;bestPeriod=candidate;bestSupport=support/max(0.001,total)}
        }
        guard bestScore>0 else{return}
        var sum=0.0,weightSum=0.0
        for (i,interval) in list.enumerated(){let multiple=max(1,(interval/bestPeriod).rounded());let p=interval/multiple;if abs(p-bestPeriod)<bestPeriod*0.1{let w=pow(0.72,Double(list.count-1-i));sum += p*w;weightSum += w}}
        let refined=weightSum>0 ? sum/weightSum : bestPeriod
        let changed=abs(refined-snapshot.period)>snapshot.period*0.10
        snapshot.period=changed ? refined : snapshot.period*0.5+refined*0.5
        snapshot.confidence=min(1,Double(strongTimes.count-2)/4)*bestSupport
        if changed,snapshot.confidence>0.6,let last=strongTimes.last{snapshot.phase=last}
    }
}

public enum BeatRenderer{
    public static func color(snapshot s:BeatSnapshot,age:Double,colour:RGB,brightness:Double,configuration c:BeatConfiguration,palette:BeatPalette?=nil)->RGB{
        let now=s.time+max(0,age)
        guard now-s.lastSignal<0.30 else{return .black}
        func pulse(_ age:Double,_ decay:Double)->Double{guard age>=0,age<max(0.3,decay*4)else{return 0};return age<0.04 ? 1 : exp(-(age-0.04)/decay)}
        if let palette{
            let latest=max(s.lastKick,max(s.lastSnare,s.lastHat))
            let selected:RGB,level:Double
            // One physical zone: priority applies only to events within the same40ms frame.
            if s.lastKick>=latest-0.04{selected=palette.kick;level=pulse(now-s.lastKick,c.decay)}
            else if s.lastSnare>=latest-0.04{selected=palette.snare;level=pulse(now-s.lastSnare,c.decay)}
            else{selected=palette.hat;level=(0.12+0.48*c.detail)*s.hatStrength*pulse(now-s.lastHat,c.decay*0.65)}
            let value=level*brightness
            return value<0.002 ? .black : .black.mixed(selected,value)
        }
        let main=s.mainStrength*pulse(now-s.lastMain,c.decay)
        let extra=(0.12+0.48*c.detail)*s.extraStrength*pulse(now-s.lastExtra,c.decay*0.65)
        let level=min(1,max(main,extra))*brightness
        return level<0.002 ? .black : .black.mixed(colour,level)
    }
}

/// 64ms Hann spectrum at 8kHz. Positive magnitude differences avoid the beating of
/// short RMS windows when sustained notes share a band. Arrays are reused per hop.
private struct AttackSpectrum:Sendable{
    private var ring=[Double](repeating:0,count:512),position=0
    private var real=[Double](repeating:0,count:512),imag=[Double](repeating:0,count:512)
    private var shortBackground=[Double](repeating:0,count:129)
    private var shortReal=[Double](repeating:0,count:256),shortImag=[Double](repeating:0,count:256)
    private let shortHann=(0..<256).map{0.5-0.5*cos(2*Double.pi*Double($0)/255)}
    private var previous=[Double](repeating:0,count:257)
    private let hann=(0..<512).map{0.5-0.5*cos(2*Double.pi*Double($0)/511)}
    mutating func append(_ x:Double){ring[position]=x;position=(position+1)%512}
    mutating func analyze()->(low:Double,mid:Double,high:Double,lowRise:Double,midRise:Double,highRise:Double,flatness:Double,spread:Double,fingerprint:[Double],lowCentroid:Double,tailSpread:Double){
        for i in 0..<512{real[i]=ring[(position+i)%512]*hann[i];imag[i]=0}
        Self.fft(real:&real,imag:&imag)
        for i in 0..<256{shortReal[i]=ring[(position+256+i)%512]*shortHann[i];shortImag[i]=0}
        Self.fft(real:&shortReal,imag:&shortImag)
        var shortSum=0.0,shortSquared=0.0
        for bin in 8...110{
            let magnitude=hypot(shortReal[bin],shortImag[bin])/64
            let residual=max(0,magnitude-shortBackground[bin])
            shortSum += residual;shortSquared += residual*residual
            let speed=magnitude<shortBackground[bin] ? 0.3 : 0.01
            shortBackground[bin] += speed*(magnitude-shortBackground[bin])
        }
        let tailSpread=shortSum*shortSum/max(1e-14,103*shortSquared)
        var levels=[Double](repeating:0,count:3),rises=[Double](repeating:0,count:3),logSum=0.0,amplitudeSum=0.0,fluxSum=0.0,fluxSquared=0.0,fingerprint=[Double](repeating:0,count:8),lowWeighted=0.0,lowFluxSum=0.0
        for bin in 2...220{
            let magnitude=hypot(real[bin],imag[bin])/128,band=bin<=11 ? 0 : bin<=90 ? 1 : 2
            if bin>=12{logSum += log(max(1e-8,magnitude));amplitudeSum += magnitude;let flux=max(0,magnitude-previous[bin]);fluxSum += flux;fluxSquared += flux*flux}
            if bin<=11{let flux=max(0,magnitude-previous[bin]);lowWeighted += flux*Double(bin)*8000/512;lowFluxSum += flux}
            let featureBand = bin<4 ? 0 : bin<8 ? 1 : bin<16 ? 2 : bin<32 ? 3 : bin<64 ? 4 : bin<128 ? 5 : bin<192 ? 6 : 7
            fingerprint[featureBand] += max(0,magnitude-previous[bin])
            levels[band] += magnitude;rises[band] += max(0,magnitude-previous[bin]);previous[bin]=magnitude
        }
        return(levels[0],levels[1],levels[2],rises[0],rises[1],rises[2],exp(logSum/209)/max(1e-8,amplitudeSum/209),fluxSum*fluxSum/max(1e-12,209*fluxSquared),fingerprint,lowWeighted/max(1e-9,lowFluxSum),tailSpread)
    }
    private static func fft(real:inout[Double],imag:inout[Double]){
        let size=real.count
        var j=0
        for i in 1..<size{var bit=size/2;while j & bit != 0{j ^= bit;bit >>= 1};j ^= bit;if i<j{real.swapAt(i,j);imag.swapAt(i,j)}}
        var length=2
        while length<=size{
            let angle = -2*Double.pi/Double(length),wr0=cos(angle),wi0=sin(angle)
            for start in stride(from:0,to:size,by:length){
                var wr=1.0,wi=0.0
                for offset in 0..<(length/2){
                    let a=start+offset,b=a+length/2,tr=wr*real[b]-wi*imag[b],ti=wr*imag[b]+wi*real[b]
                    real[b]=real[a]-tr;imag[b]=imag[a]-ti;real[a] += tr;imag[a] += ti
                    let next=wr*wr0-wi*wi0;wi=wr*wi0+wi*wr0;wr=next
                }
            }
            length *= 2
        }
    }

}


public struct BeatEventMatch:Sendable{
    public let matched:Int,missed:Int,falseHits:Int
    public let maximumError:Double,totalError:Double
}
/// Sorted one-to-one matching: one detection can never stand in for two close drum hits.
public enum BeatEventMatcher{
    public static func match(expected:[Double],detected:[Double],tolerance:Double)->BeatEventMatch{
        let expected=expected.sorted(),detected=detected.sorted()
        var i=0,j=0,matched=0,maxError=0.0,totalError=0.0
        while i<expected.count,j<detected.count{
            let delta=detected[j]-expected[i]
            if delta < -tolerance{j += 1}
            else if delta > tolerance{i += 1}
            else{matched += 1;maxError=max(maxError,abs(delta));totalError += abs(delta);i += 1;j += 1}
        }
        return BeatEventMatch(matched:matched,missed:expected.count-matched,falseHits:detected.count-matched,maximumError:maxError,totalError:totalError)
    }
}

/// Temporary, amplitude-invariant fingerprints. Only convincing repeated attacks train;
/// unfamiliar attacks need probation once a sound family is established. No audio is retained.
public struct PercussionMemory:Sendable{
    private struct Template:Sendable{var kind:PercussionKind,vector:[Double],count:Int,last:Double}
    private var learned:[Template]=[],probation:[Template]=[]
    public var learnedCount:Int{learned.count}
    public var learningCount:Int{probation.count}
    public init(){}
    /// Compare across all classes; caller uses this only for an ambiguous joint decision.
    public func recognizedKind(features:[Double])->PercussionKind?{
        let norm=sqrt(features.reduce(0){$0+$1*$1});guard norm>1e-8 else{return nil}
        let vector=features.map{$0/norm}
        let scores=learned.filter{$0.vector.count==vector.count}.map{template in (template.kind,zip(vector,template.vector).reduce(0){$0+$1.0*$1.1})}.sorted{$0.1>$1.1}
        guard let best=scores.first,best.1>0.94 else{return nil}
        if let competing=scores.first(where:{$0.0 != best.0}),best.1-competing.1<0.04{return nil}
        return best.0
    }
    public mutating func reset(){learned.removeAll();probation.removeAll()}
    public mutating func accepts(kind:PercussionKind,features:[Double],time:Double,convincing:Bool,eligible:Bool)->Bool{
        let magnitude=sqrt(features.reduce(0){$0+$1*$1})
        guard magnitude>1e-8,features.allSatisfy({$0.isFinite}) else{return false}
        let vector=features.map{$0/magnitude}
        func similarity(_ other:[Double])->Double{guard other.count==vector.count else{return 0};return zip(vector,other).reduce(0){$0+$1.0*$1.1}}
        probation.removeAll{time-$0.last>3}
        if let index=learned.indices.filter({learned[$0].kind==kind}).max(by:{similarity(learned[$0].vector)<similarity(learned[$1].vector)}),similarity(learned[index].vector)>(convincing && eligible ? 0.85 : 0.90){
            let agreement=similarity(learned[index].vector)
            guard eligible || agreement>0.97 else{return false}
            // Quiet matches may render, but cannot drift a learned template into vocals.
            if convincing{learned[index].vector=zip(learned[index].vector,vector).map{$0*0.92+$1*0.08};let norm=sqrt(learned[index].vector.reduce(0){$0+$1*$1});learned[index].vector=learned[index].vector.map{$0/norm};learned[index].last=time}
            return true
        }
        guard convincing,eligible else{return false}
        let established=learned.contains{$0.kind==kind}
        if let index=probation.firstIndex(where:{$0.kind==kind && similarity($0.vector)>0.90}){
            if time-probation[index].last>=0.085{probation[index].count += 1;probation[index].last=time}
            if probation[index].count>=3{
                let candidate=probation.remove(at:index)
                let same=learned.indices.filter{learned[$0].kind==kind}
                if same.count>=2,let oldest=same.min(by:{learned[$0].last<learned[$1].last}){learned.remove(at:oldest)}
                learned.append(candidate);return true
            }
        }else{
            probation.append(Template(kind:kind,vector:vector,count:1,last:time))
            if probation.count>8{probation.removeFirst()}
        }
        return !established
    }
}


/// One event group gathers a35ms target (one5ms hop granularity) of joint evidence. Classification happens once.
private struct JointAttack:Sendable{
    let start:Double
    var lowFlux=0.0,midFlux=0.0,highFlux=0.0,spread=0.0,weightedCentroid=0.0
    var lowScore=0.0,highScore=0.0,tailLow=0.0,tailHigh=0.0,peakHigh=0.0,tailSpread=0.0,fastHigh=false
    var fingerprint=[Double](repeating:0,count:8)
    mutating func include(lowFlux:Double,midFlux:Double,highFlux:Double,fingerprint:[Double],spread:Double,lowCentroid:Double,low:Double,high:Double,fastHigh:Bool,lowScore:Double,highScore:Double,tailSpread:Double){
        self.lowFlux += lowFlux;self.midFlux += midFlux;self.highFlux += highFlux;self.spread=max(self.spread,spread)
        weightedCentroid += lowCentroid*lowFlux;tailLow=low;tailHigh=high;peakHigh=max(peakHigh,high);self.fastHigh = self.fastHigh || fastHigh
        self.tailSpread=tailSpread
        self.lowScore=max(self.lowScore,lowScore);self.highScore=max(self.highScore,highScore)
        for i in self.fingerprint.indices{self.fingerprint[i] += fingerprint[i]}
    }
    func classify(focus:Bool)->(kind:PercussionKind,confidence:Double)?{
        let all=max(1e-9,lowFlux+midFlux+highFlux),lowShare=lowFlux/all
        let centroid=weightedCentroid/max(1e-9,lowFlux)
        let decaying=tailHigh/max(1e-6,peakHigh)<0.90
        let broadband=spread>0.18 && highFlux/all>0.08 && tailSpread>0.18 && (fastHigh || decaying)
        let noisyTail=tailHigh/max(1e-6,tailLow)>0.10 && tailHigh/max(1e-6,peakHigh)>0.15
        let body=midFlux/max(1e-9,highFlux)
        let resonant=lowShare>0.30 || lowScore>highScore*1.5 || (lowScore>1.5 && tailLow>tailHigh*2)
        // A low fundamental plus broadband simultaneous attack is one combined kick group.
        if resonant && (!focus || lowShare>=0.15) && (!broadband || !noisyTail || (centroid<95 && lowScore>1.5 && tailLow>tailHigh*2)){
            return(.kick,(centroid<95 && tailLow>tailHigh*2) ? 0.95 : broadband ? 0.78 : 0.95)
        }
        if broadband,(!focus || decaying){
            return body>0.35 ? (.snare,0.90) : (.hat,0.90)
        }
        if !focus{
            return lowShare>0.40 ? (.kick,0.76) : body>0.35 ? (.snare,0.76) : (.hat,0.76)
        }
        return nil
    }
}
