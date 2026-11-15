import XCTest
@testable import ChromaCore
final class BeatTests:XCTestCase{
    func testOffGridDrumsAreFullFlashesAndGridDoesNotInventHits(){
        var s=BeatSnapshot();s.time=2.25;s.lastSignal=2.25;s.lastOnset=2.25;s.lastMain=2.25;s.mainStrength=1;s.phase=2;s.period=0.5;s.confidence=1
        let c=BeatConfiguration()
        XCTAssertEqual(BeatRenderer.color(snapshot:s,age:0,colour:RGB(0,0,1),brightness:1,configuration:c).b,1,accuracy:0.001)
        // No drum occurred at 2.5: the tempo guide must not create a new flash there.
        s.time=2.5;s.lastSignal=2.5
        XCTAssertLessThan(BeatRenderer.color(snapshot:s,age:0,colour:RGB(0,0,1),brightness:1,configuration:c).b,0.4)
    }
    func testFullMixSyncopationFollowsActualKickAndSnare(){
        let fixture=GrooveFixture.make(rate:8000)
        var detector=BeatDetector(configuration:BeatConfiguration())
        var detected:[Double]=[],last = -Double.infinity
        for start in stride(from:0,to:fixture.samples.count,by:40){
            detector.process(Array(fixture.samples[start..<min(start+40,fixture.samples.count)]),sampleRate:8000)
            if detector.snapshot.lastMain>last{last=detector.snapshot.lastMain;detected.append(last)}
        }
        let result=BeatEventMatcher.match(expected:fixture.hits,detected:detected,tolerance:0.08)
        let matches=result.matched,falsePositives=result.falseHits
        print("GROOVE expected=\(fixture.hits.count) detected=\(detected.count) matched=\(matches) false=\(falsePositives)")
        XCTAssertGreaterThanOrEqual(Double(matches)/Double(fixture.hits.count),0.9)
        XCTAssertLessThanOrEqual(falsePositives,3)
    }
    func testFullMixGrooveBenchmarkAcrossRhythmsAndLevels(){
        let styles:[(String,[Double],[Double])]=[
            ("syncopated",[0,0.75,0.875,1.5],[0.5,1.25]),
            ("snare-led",[],[0,0.5,0.875,1.5]),
            ("swing",[0,0.67,1,1.67],[0.33,1.33]),
            ("sparse",[0],[1.25]),
            ("dense",[0,0.375,0.5,1,1.375,1.5],[0.75,1.75])]
        for (name,kicks,snares) in styles{
            for level in [0.4,1.0]{
                let fixture=GrooveFixture.make(rate:8000,kicks:kicks,snares:snares,level:level)
                var detector=BeatDetector(configuration:BeatConfiguration()),detected:[Double]=[],last = -Double.infinity
                for start in stride(from:0,to:fixture.samples.count,by:40){
                    detector.process(Array(fixture.samples[start..<min(start+40,fixture.samples.count)]),sampleRate:8000)
                    if detector.snapshot.lastMain>last{last=detector.snapshot.lastMain;detected.append(last)}
                }
                let result=BeatEventMatcher.match(expected:fixture.hits,detected:detected,tolerance:0.08)
                let matches=result.matched,falsePositives=result.falseHits
                print("GROOVE_BENCH \(name) level=\(level) expected=\(fixture.hits.count) matched=\(matches) false=\(falsePositives)")
                XCTAssertGreaterThanOrEqual(Double(matches)/Double(fixture.hits.count),0.9,name)
                XCTAssertLessThanOrEqual(falsePositives,3,name)
            }
        }
    }
    func testSustainedFullMixDoesNotInventRecurringDrums(){
        let fixture=GrooveFixture.make(rate:8000,kicks:[],snares:[])
        var detector=BeatDetector(configuration:BeatConfiguration())
        detector.process(fixture.samples,sampleRate:8000)
        XCTAssertLessThanOrEqual(detector.snapshot.mainCount,2)
        XCTAssertNil(detector.snapshot.bpm)
    }
    func testSoftDrumsRemainDetectableBehindSustainedFullMix(){
        let fixture=GrooveFixture.make(rate:8000,drumLevel:0.30)
        var detector=BeatDetector(configuration:BeatConfiguration()),detected:[Double]=[],last = -Double.infinity
        for start in stride(from:0,to:fixture.samples.count,by:40){
            detector.process(Array(fixture.samples[start..<min(start+40,fixture.samples.count)]),sampleRate:8000)
            if detector.snapshot.lastMain>last{last=detector.snapshot.lastMain;detected.append(last)}
        }
        let result=BeatEventMatcher.match(expected:fixture.hits,detected:detected,tolerance:0.08)
        let matches=result.matched,falseHits=result.falseHits
        print("SOFT_DRUMS matched=\(matches)/\(fixture.hits.count) false=\(falseHits)")
        XCTAssertGreaterThanOrEqual(matches,22)
        XCTAssertLessThanOrEqual(falseHits,3)
    }
    func testOneEventCannotMatchTwoCloseDrumHits(){
        let match=BeatEventMatcher.match(expected:[0,0.1],detected:[0.05],tolerance:0.08)
        XCTAssertEqual(match.matched,1);XCTAssertEqual(match.missed,1)
    }
    func testFullMixGrooveChangingTempoRetainsCloseKickPairs(){
        let fixture=GrooveFixture.make(rate:8000,tempi:[120,150,100,140])
        var detector=BeatDetector(configuration:BeatConfiguration()),detected:[Double]=[],last = -Double.infinity
        for start in stride(from:0,to:fixture.samples.count,by:40){
            detector.process(Array(fixture.samples[start..<min(start+40,fixture.samples.count)]),sampleRate:8000)
            if detector.snapshot.lastMain>last{last=detector.snapshot.lastMain;detected.append(last)}
        }
        let match=BeatEventMatcher.match(expected:fixture.hits,detected:detected,tolerance:0.08)
        print("GROOVE_TEMPO matched=\(match.matched)/\(fixture.hits.count) false=\(match.falseHits) maxError=\(match.maximumError)")
        XCTAssertGreaterThanOrEqual(match.matched,22);XCTAssertLessThanOrEqual(match.falseHits,3)
    }
    func test48kHzStreamingAnalysisStaysWithinRealtimeBudget(){
        let rate=48000
        let samples=BeatFixture.samples(segments:[(120,2)],sampleRate:rate,fills:true)
        var detector=BeatDetector(configuration:BeatConfiguration()),maximum=0.0
        let started=ProcessInfo.processInfo.systemUptime
        samples.withUnsafeBufferPointer{buffer in
            for offset in stride(from:0,to:buffer.count,by:512){
                let chunk=UnsafeBufferPointer(start:buffer.baseAddress!+offset,count:min(512,buffer.count-offset))
                let before=ProcessInfo.processInfo.systemUptime
                detector.process(chunk,sampleRate:Double(rate))
                maximum=max(maximum,ProcessInfo.processInfo.systemUptime-before)
            }
        }
        let elapsed=ProcessInfo.processInfo.systemUptime-started
        print(String(format:"BEAT_PERFORMANCE audioSeconds=2 elapsed=%.6f max512FrameChunk=%.6f",elapsed,maximum))
        XCTAssertLessThan(elapsed,1.0)
    }
    func testVocalLikeFormantsAndConsonantsDoNotBecomeRepeatedDrumFlashes(){
        var detector=BeatDetector(configuration:BeatConfiguration())
        let pcm=VocalFixture.samples(rate:8000)
        var previous = -Double.infinity
        for start in stride(from:0,to:pcm.count,by:40){
            detector.process(Array(pcm[start..<min(start+40,pcm.count)]),sampleRate:8000)
            let s=detector.snapshot
            if s.lastOnset>previous{previous=s.lastOnset;print("VOCAL_EVENT t=\(s.lastOnset) kick=\(s.kickCount) snare=\(s.snareCount) hat=\(s.hatCount) flat=\(s.spectralFlatness) low=\(s.bassLevel) mid=\(s.midLevel) high=\(s.highLevel)")}
        }
        print("VOCAL_ONLY drums=\(detector.snapshot.mainCount) extras=\(detector.snapshot.extraCount)")
        XCTAssertLessThanOrEqual(detector.snapshot.mainCount,3)
        XCTAssertLessThanOrEqual(detector.snapshot.extraCount,3)
        XCTAssertEqual(detector.snapshot.learnedTemplates,0)
    }
    func testPercussionPalettePriorityAndSingleColourFallback(){
        var s=BeatSnapshot();s.time=1;s.lastSignal=1;s.lastMain=1;s.mainStrength=1
        s.lastKick=1;s.lastSnare=1.01;s.lastHat=1.02;s.hatStrength=1
        let palette=BeatPalette(),config=BeatConfiguration()
        // Current snapshot time must include all events; collisions prefer bass/kick.
        s.time=1.02
        XCTAssertEqual(BeatRenderer.color(snapshot:s,age:0,colour:RGB(0,1,0),brightness:1,configuration:config,palette:palette),RGB(1,0,0))
        s.time=1.15;s.lastSnare=1.15
        XCTAssertEqual(BeatRenderer.color(snapshot:s,age:0,colour:RGB(0,1,0),brightness:1,configuration:config,palette:palette),RGB(0,0,1))
        s.time=1.3;s.lastSignal=1.3;s.lastHat=1.3
        let hat=BeatRenderer.color(snapshot:s,age:0,colour:.white,brightness:1,configuration:config,palette:palette)
        XCTAssertGreaterThan(hat.r,0);XCTAssertEqual(hat.r,hat.g);XCTAssertEqual(hat.b,0)
        s.time=1;s.lastMain=1
        XCTAssertEqual(BeatRenderer.color(snapshot:s,age:0,colour:RGB(0,1,0),brightness:1,configuration:config),RGB(0,1,0))
    }
    func testColourTargetsAndOptionalPresetFieldsRemainCompatible()throws{
        var p=Preset(name:"Colours");p.primary=RGB(0.2,0.4,0.6)
        PresetColourTarget.kick.set(RGB(0,1,1),in:&p)
        XCTAssertEqual(p.beatPalette.kick,RGB(0,1,1));XCTAssertEqual(p.primary,RGB(0.2,0.4,0.6))
        p.beatMulticolour=false;p.beatPercussionFocus=false
        XCTAssertEqual(try JSONDecoder().decode(Preset.self,from:JSONEncoder().encode(p)),p)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as? [String:Any])
        for field in ["beatMulticolour","beatPercussionFocus","beatKickColour","beatSnareColour","beatHatColour"]{json.removeValue(forKey:field)}
        let old=try JSONDecoder().decode(Preset.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(old.primary,p.primary);XCTAssertEqual(old.beatPalette,BeatPalette());XCTAssertTrue(old.beatConfiguration.percussionFocus)
    }
    func testKnownPercussionKindsClassifySeparately(){
        var pcm=[Float](repeating:0,count:24000)
        BeatFixture.addKick(&pcm,time:0.5,rate:8000,amplitude:0.8)
        BeatFixture.addSnare(&pcm,time:1.2,rate:8000)
        var seed:UInt32=71,previous=0.0
        for i in 0..<400{seed=1664525 &* seed &+ 1013904223;let noise=Double(seed)/Double(UInt32.max)*2-1;let high=(noise-previous)*0.5;previous=noise;pcm[16000+i] += Float(0.4*high*exp(-Double(i)/8000/0.012))}
        var detector=BeatDetector(configuration:BeatConfiguration())
        detector.process(pcm,sampleRate:8000)
        let s=detector.snapshot
        print("TYPED kick=\(s.kickCount) snare=\(s.snareCount) high=\(s.hatCount)")
        XCTAssertEqual(s.kickCount,1);XCTAssertEqual(s.snareCount,1);XCTAssertEqual(s.hatCount,1)
    }
    func testDrumsRemainVisibleWithVocalLikeInterference(){
        var fixture=GrooveFixture.make(rate:8000)
        let vocal=VocalFixture.samples(rate:8000)
        for i in vocal.indices{fixture.samples[i] += vocal[i]*0.8}
        var detector=BeatDetector(configuration:BeatConfiguration()),detected:[Double]=[],last = -Double.infinity
        for start in stride(from:0,to:fixture.samples.count,by:40){
            detector.process(Array(fixture.samples[start..<min(start+40,fixture.samples.count)]),sampleRate:8000)
            if detector.snapshot.lastMain>last{last=detector.snapshot.lastMain;detected.append(last)}
        }
        let match=BeatEventMatcher.match(expected:fixture.hits,detected:detected,tolerance:0.08)
        print("VOCAL_MIX counts kick=\(detector.snapshot.kickCount) snare=\(detector.snapshot.snareCount) hats=\(detector.snapshot.hatCount)")
        print("VOCAL_MIX misses=\(fixture.hits.filter{t in !detected.contains{abs($0-t)<0.08}})")
        print("VOCAL_MIX matched=\(match.matched)/\(fixture.hits.count) false=\(match.falseHits)")
        XCTAssertGreaterThanOrEqual(match.matched,21);XCTAssertLessThanOrEqual(match.falseHits,4)
    }
    func testPercussionFingerprintsLearnQuietMatchesRejectUncertainAndRelearn(){
        var memory=PercussionMemory()
        let kick=[1.0,0.1,0,0],other=[0.0,0,0.2,1.0]
        for time in [0.0,0.5,1.0]{XCTAssertTrue(memory.accepts(kind:.kick,features:kick,time:time,convincing:true,eligible:true))}
        XCTAssertEqual(memory.learnedCount,1)
        XCTAssertTrue(memory.accepts(kind:.kick,features:kick.map{$0*0.1},time:1.5,convincing:false,eligible:true))
        XCTAssertFalse(memory.accepts(kind:.kick,features:other,time:1.7,convincing:false,eligible:false))
        XCTAssertFalse(memory.accepts(kind:.kick,features:other,time:2,convincing:true,eligible:true))
        XCTAssertFalse(memory.accepts(kind:.kick,features:other,time:2.5,convincing:true,eligible:true))
        XCTAssertTrue(memory.accepts(kind:.kick,features:other,time:3,convincing:true,eligible:true))
        XCTAssertEqual(memory.learnedCount,2)
        for time in [3.5,4.2,4.7]{XCTAssertTrue(memory.accepts(kind:.snare,features:other,time:time,convincing:true,eligible:true))}
        XCTAssertEqual(memory.learnedCount,3)
        memory.reset();XCTAssertEqual(memory.learnedCount,0);XCTAssertEqual(memory.learningCount,0)
    }
    func testNewPercussionTimbreRelearnsWhileMusicContinues(){
        var pcm=(0..<60000).map{Float(0.03*sin(2*Double.pi*440*Double($0)/8000))}
        for i in 0..<6{BeatFixture.addKick(&pcm,time:0.5+Double(i)*0.5,rate:8000,amplitude:0.8)}
        for i in 0..<6{BeatFixture.addKick(&pcm,time:3.5+Double(i)*0.5,rate:8000,amplitude:0.8,frequency:130)}
        var detector=BeatDetector(configuration:BeatConfiguration())
        detector.process(pcm,sampleRate:8000)
        print("RELEARN kick=\(detector.snapshot.kickCount) learned=\(detector.snapshot.learnedTemplates) last=\(detector.snapshot.lastKick)")
        XCTAssertGreaterThanOrEqual(detector.snapshot.kickCount,9)
        XCTAssertGreaterThan(detector.snapshot.lastKick,6)
        XCTAssertGreaterThanOrEqual(detector.snapshot.learnedTemplates,2)
    }
    func testOldPresetsRemainDecodableAndBeatSettingsRoundTrip()throws{
        let original=Preset(name:"Old audio preset")
        let data=try JSONEncoder().encode(original)
        let decoded=try JSONDecoder().decode(Preset.self,from:data)
        XCTAssertEqual(decoded.beatConfiguration,BeatConfiguration(gate:0.01))
        var beat=decoded;beat.mode = .beatAdapt;beat.beatSensitivity=1.4;beat.beatDetail=0.8;beat.beatDecay=0.22
        XCTAssertEqual(try JSONDecoder().decode(Preset.self,from:JSONEncoder().encode(beat)),beat)
        XCTAssertTrue(beat.mode.usesAudio)
    }
    func testActualPCMKickPatternLocks120AndFillsDoNotDoubleTempo(){
        var detector=BeatDetector(configuration:BeatConfiguration())
        let pcm=BeatFixture.samples(segments:[(120,9)],sampleRate:8000,fills:true,doubles:true)
        detector.process(pcm,sampleRate:8000)
        let s=detector.snapshot
        XCTAssertEqual(s.bpm ?? 0,120,accuracy:3)
        XCTAssertGreaterThan(s.confidence,0.6)
        // Both real kick and snare now flash strongly; the 30ms kick echo stays suppressed.
        XCTAssertGreaterThanOrEqual(s.mainCount,34)
        XCTAssertLessThanOrEqual(s.mainCount,38)
    }
    func testTempoChangeAdaptsAndSilenceDoesNotInventPulses(){
        var detector=BeatDetector(configuration:BeatConfiguration())
        detector.process(BeatFixture.samples(segments:[(120,6),(150,7)],sampleRate:8000),sampleRate:8000)
        XCTAssertEqual(detector.snapshot.bpm ?? 0,150,accuracy:4)
        let before=detector.snapshot.mainCount
        detector.process([Float](repeating:0,count:8000),sampleRate:8000)
        XCTAssertEqual(detector.snapshot.mainCount,before)
        XCTAssertNil(detector.snapshot.bpm)
        XCTAssertEqual(BeatRenderer.color(snapshot:detector.snapshot,age:0,colour:RGB(0,0,1),brightness:1,configuration:BeatConfiguration()),.black)
    }
    func testSteadyToneCannotClaimATempo(){
        var detector=BeatDetector(configuration:BeatConfiguration())
        detector.process((0..<64000).map{Float(0.4*sin(2*Double.pi*55*Double($0)/8000))},sampleRate:8000)
        XCTAssertNil(detector.snapshot.bpm)
        XCTAssertLessThan(detector.snapshot.mainCount,4)
    }
    func testNewSongAfterSilenceReacquiresWithoutOldTempoHistory(){
        var detector=BeatDetector(configuration:BeatConfiguration())
        detector.process(BeatFixture.samples(segments:[(120,5)],sampleRate:8000),sampleRate:8000)
        detector.process([Float](repeating:0,count:24000),sampleRate:8000)
        XCTAssertEqual(detector.snapshot.learnedTemplates,0);XCTAssertEqual(detector.snapshot.learningTemplates,0)
        detector.process(BeatFixture.samples(segments:[(150,4)],sampleRate:8000),sampleRate:8000)
        XCTAssertEqual(detector.snapshot.bpm ?? 0,150,accuracy:4)
    }
    func testSelectedFlashColourAndSmoothPulseDecay(){
        var detector=BeatDetector(configuration:BeatConfiguration())
        detector.process(BeatFixture.samples(segments:[(120,0.05)],sampleRate:8000),sampleRate:8000)
        let s=detector.snapshot,c=RGB(0.1,0.3,1)
        let early=BeatRenderer.color(snapshot:s,age:0,colour:c,brightness:1,configuration:BeatConfiguration())
        let later=BeatRenderer.color(snapshot:s,age:0.1,colour:c,brightness:1,configuration:BeatConfiguration())
        XCTAssertGreaterThan(early.b,0.5);XCTAssertGreaterThan(early.b,later.b)
        XCTAssertEqual(early.r/early.b,0.1,accuracy:0.001)
        XCTAssertEqual(early.g/early.b,0.3,accuracy:0.001)
        XCTAssertEqual(BeatRenderer.color(snapshot:s,age:1,colour:c,brightness:1,configuration:BeatConfiguration()),.black)
    }
}

enum BeatFixture{
    static func samples(segments:[(Double,Double)],sampleRate:Int,fills:Bool=false,doubles:Bool=false)->[Float]{
        let duration=segments.reduce(0){$0+$1.1}
        var data=[Float](repeating:0,count:Int(duration*Double(sampleRate)))
        var cursor=0.0
        for (bpm,length) in segments{
            let period=60/bpm
            var beat=0.0
            while beat<length{
                addKick(&data,time:cursor+beat,rate:sampleRate,amplitude:0.8)
                if doubles{addKick(&data,time:cursor+beat+0.03,rate:sampleRate,amplitude:0.3)}
                if fills{addSnare(&data,time:cursor+beat+period/2,rate:sampleRate)}
                beat += period
            }
            cursor += length
        }
        return data
    }
    static func addKick(_ data:inout[Float],time:Double,rate:Int,amplitude:Double,frequency:Double=55){
        let start=Int(time*Double(rate))
        for i in 0..<Int(0.13*Double(rate)) where start+i<data.count{
            let t=Double(i)/Double(rate)
            data[start+i] += Float(amplitude*sin(2*Double.pi*frequency*t)*exp(-t/0.035))
        }
    }
    static func addSnare(_ data:inout[Float],time:Double,rate:Int,amplitude:Double=1){
        let start=Int(time*Double(rate));var seed:UInt32=12345
        for i in 0..<Int(0.07*Double(rate)) where start+i<data.count{
            seed=1664525 &* seed &+ 1013904223
            let noise=Double(seed)/Double(UInt32.max)*2-1,t=Double(i)/Double(rate)
            data[start+i] += Float(amplitude*noise*0.5*exp(-t/0.018))
        }
    }
}

// Synthetic full mix: syncopated drums plus continuous synth, bass and a moving vocal-like formant.
enum GrooveFixture{
    static func make(rate:Int,kicks:[Double]=[0,0.75,0.875,1.5],snares:[Double]=[0.5,1.25],level:Double=1,drumLevel:Double=1,tempi:[Double]=[120,120,120,120])->(samples:[Float],hits:[Double]){
        let duration=10.5
        var pcm=(0..<Int(duration*Double(rate))).map{i -> Float in
            let t=Double(i)/Double(rate)
            guard t>=0.4,t<10 else{return 0}
            let melody=0.075*sin(2*Double.pi*440*t)+0.045*sin(2*Double.pi*660*t)
            let bass=0.12*sin(2*Double.pi*82.4*t)
            let voice=0.07*(0.7+0.3*sin(2*Double.pi*3*t))*sin(2*Double.pi*220*t+0.4*sin(2*Double.pi*5*t))
            return Float(melody+bass+voice)
        }
        var hits:[Double]=[]
        var start=0.5
        for bpm in tempi{
            let scale=120/bpm
            for offset in kicks{let t=start+offset*scale;BeatFixture.addKick(&pcm,time:t,rate:rate,amplitude:0.75*drumLevel);hits.append(t)}
            for offset in snares{let t=start+offset*scale;BeatFixture.addSnare(&pcm,time:t,rate:rate,amplitude:drumLevel);hits.append(t)}
            start += 2*scale
        }
        return(pcm.map{Float(level)*$0},hits.sorted())
    }
}


enum VocalFixture{
    static func samples(rate:Int)->[Float]{
        var pcm=[Float](repeating:0,count:rate*8),phase=0.0,seed:UInt32=718
        for i in pcm.indices{
            let t=Double(i)/Double(rate),syllable=t.truncatingRemainder(dividingBy:0.6)
            let envelope=min(1,syllable/0.035)*exp(-max(0,syllable-0.1)/0.16)
            let f0=135+30*sin(2*Double.pi*0.7*t)
            phase += 2*Double.pi*f0/Double(rate)
            var voiced=0.0
            for harmonic in 1...22{
                let frequency=f0*Double(harmonic)
                let formant=exp(-pow((frequency-600)/220,2))+0.7*exp(-pow((frequency-1450)/280,2))+0.5*exp(-pow((frequency-2500)/350,2))
                voiced += formant*sin(Double(harmonic)*phase)/Double(harmonic)
            }
            seed=1664525 &* seed &+ 1013904223
            let noise=Double(seed)/Double(UInt32.max)*2-1
            let sibilant=max(0,1-abs(syllable-0.42)/0.06)*noise*0.09
            let plosive=syllable<0.006 ? noise*0.06 : 0
            pcm[i]=Float(0.45*envelope*voiced+sibilant+plosive+0.035*sin(2*Double.pi*440*t))
        }
        return pcm
    }
}
