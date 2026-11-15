import XCTest
@testable import ChromaCore

final class PercussionBenchmarkTests:XCTestCase{
    func testCoincidentHitsAreOneStableGroupWhileCloseDoubleKicksStaySeparate(){
        for offset in [0.0,0.01,0.02,0.03]{
            var pcm=[Float](repeating:0,count:4000)
            BeatFixture.addKick(&pcm,time:0.1,rate:8000,amplitude:0.8)
            BeatFixture.addSnare(&pcm,time:0.1+offset,rate:8000)
            var detector=BeatDetector(configuration:BeatConfiguration(adaptive:false))
            detector.process(pcm,sampleRate:8000)
            let s=detector.snapshot
            print("COLLISION offset=\(offset) kick=\(s.kickCount) snare=\(s.snareCount) high=\(s.hatCount)")
            XCTAssertEqual(s.kickCount+s.snareCount+s.hatCount,1)
            XCTAssertEqual(s.kickCount,1)
            // The same collision amid a continuous full-mix backing must stay one colour group.
            var mixed=(0..<12000).map{i -> Float in let t=Double(i)/8000;return Float(0.08*sin(2*Double.pi*82.4*t)+0.04*sin(2*Double.pi*440*t))}
            BeatFixture.addKick(&mixed,time:1,rate:8000,amplitude:0.8)
            BeatFixture.addSnare(&mixed,time:1+offset,rate:8000)
            var full=BeatDetector(configuration:BeatConfiguration(adaptive:false)),groups:[BeatSnapshot]=[],last = -Double.infinity
            for start in stride(from:0,to:mixed.count,by:40){
                full.process(Array(mixed[start..<min(start+40,mixed.count)]),sampleRate:8000)
                let current=full.snapshot
                if current.lastOnset>last{last=current.lastOnset;if last>0.8{groups.append(current)}}
            }
            XCTAssertEqual(groups.count,1)
            if let group=groups.first{
                XCTAssertGreaterThan(group.lastKick,1)
                for age in [0.0,0.01,0.03]{let color=BeatRenderer.color(snapshot:group,age:age,colour:.white,brightness:1,configuration:BeatConfiguration(),palette:BeatPalette());XCTAssertGreaterThan(color.r,0);XCTAssertEqual(color.g,0);XCTAssertEqual(color.b,0)}
            }
        }
        for gap in [0.1,0.125]{
            var pcm=[Float](repeating:0,count:4000)
            BeatFixture.addKick(&pcm,time:0.1,rate:8000,amplitude:0.8)
            BeatFixture.addKick(&pcm,time:0.1+gap,rate:8000,amplitude:0.8)
            var detector=BeatDetector(configuration:BeatConfiguration(adaptive:false))
            detector.process(pcm,sampleRate:8000)
            XCTAssertEqual(detector.snapshot.kickCount,2)
        }
    }
    func testJointDecisionLatencyAndCrossTypeFingerprintRecognition(){
        var pcm=[Float](repeating:0,count:4000)
        BeatFixture.addKick(&pcm,time:0.1,rate:8000,amplitude:0.8)
        var detector=BeatDetector(configuration:BeatConfiguration())
        detector.process(pcm,sampleRate:8000)
        XCTAssertGreaterThan(detector.snapshot.lastKick,0.1)
        XCTAssertLessThanOrEqual(detector.snapshot.lastKick-0.1,0.08)
        var memory=PercussionMemory()
        for t in [0.0,0.5,1.0]{_ = memory.accepts(kind:.snare,features:[0,0.2,1,0.5],time:t,convincing:true,eligible:true)}
        XCTAssertEqual(memory.recognizedKind(features:[0,0.02,0.1,0.05]),.snare)
        for t in [1.5,2.0,2.5]{_ = memory.accepts(kind:.kick,features:[0,0.2,1,0.5],time:t,convincing:true,eligible:true)}
        XCTAssertNil(memory.recognizedKind(features:[0,0.2,1,0.5]))
    }
    func testJointClassificationAndQuietHoldoutBenchmark(){
        for (name,seed,variant,drumLevel,overall) in [
            ("tuning-boomy",UInt32(91),0,1.0,1.0),
            ("tuning-soft",UInt32(91),0,0.3,1.0),
            ("holdout-boomy",UInt32(8231),1,1.0,1.0),
            ("holdout-soft",UInt32(8231),1,0.1,1.0),
            ("holdout-quiet-track",UInt32(4421),2,1.0,0.03)]{
            let fixture=DrumMixFixture.make(seed:seed,variant:variant,drumLevel:drumLevel,overall:overall)
            var detector=BeatDetector(configuration:BeatConfiguration()),events:[DrumEvent]=[]
            var kick = -Double.infinity,snare = -Double.infinity,hat = -Double.infinity
            for start in stride(from:0,to:fixture.pcm.count,by:40){
                detector.process(Array(fixture.pcm[start..<min(start+40,fixture.pcm.count)]),sampleRate:8000)
                let s=detector.snapshot
                if s.lastKick>kick{kick=s.lastKick;events.append(DrumEvent(time:kick,kind:.kick))}
                if s.lastSnare>snare{snare=s.lastSnare;events.append(DrumEvent(time:snare,kind:.snare))}
                if s.lastHat>hat{hat=s.lastHat;events.append(DrumEvent(time:hat,kind:.hat))}
            }
            let result=DrumMixFixture.score(expected:fixture.events,detected:events)
            if name=="holdout-soft"{
                print("SOFT_MISSES \(fixture.events.filter{e in !events.contains{abs($0.time-e.time)<0.08}}.map{String(format:"%.3f",$0.time)+$0.kind.rawValue})")
                for focus in [true,false]{
                    var comparison=BeatDetector(configuration:BeatConfiguration(percussionFocus:focus,adaptive:false)),found:[DrumEvent]=[]
                    var times=[Double](repeating:-Double.infinity,count:3)
                    for start in stride(from:0,to:fixture.pcm.count,by:40){
                        comparison.process(Array(fixture.pcm[start..<min(start+40,fixture.pcm.count)]),sampleRate:8000)
                        let c=comparison.snapshot
                        for (i,item) in [(c.lastKick,PercussionKind.kick),(c.lastSnare,.snare),(c.lastHat,.hat)].enumerated(){if item.0>times[i]{times[i]=item.0;found.append(DrumEvent(time:item.0,kind:item.1))}}
                    }
                    let r=DrumMixFixture.score(expected:fixture.events,detected:found)
                    print("SOFT_ABLATION focus=\(focus) adaptive=false matched=\(r.matched) correct=\(r.correct) false=\(r.falseHits)")
                }
            }
            let latency=result.latencies
            let p50=latency.isEmpty ? 0 : latency[latency.count/2],p95=latency.isEmpty ? 0 : latency[min(latency.count-1,Int(Double(latency.count)*0.95))]
            print(String(format:"DSP_LATENCY %@ p50=%.1fms p95=%.1fms max=%.1fms",name,p50*1000,p95*1000,(latency.last ?? 0)*1000))
            print("DSP_BENCH \(name) expected=\(fixture.events.count) matched=\(result.matched) correct=\(result.correct) false=\(result.falseHits) confusion=\(result.matrix)")
            XCTAssertGreaterThanOrEqual(Double(result.matched)/Double(fixture.events.count),0.85,name)
            XCTAssertGreaterThanOrEqual(Double(result.correct)/Double(fixture.events.count),0.78,name)
            XCTAssertLessThanOrEqual(result.falseHits,4,name)
        }
    }
}
struct DrumEvent{let time:Double,kind:PercussionKind}
enum DrumMixFixture{
    static func make(seed initialSeed:UInt32,variant:Int,drumLevel:Double,overall:Double)->(pcm:[Float],events:[DrumEvent]){
        let rate=8000
        var seed=initialSeed,pcm=(0..<76000).map{i->Float in let t=Double(i)/8000;return Float(0.08*sin(2*Double.pi*82.4*t)+0.04*sin(2*Double.pi*440*t)+0.025*sin(2*Double.pi*659.3*t))},events:[DrumEvent]=[]
        func noise()->Double{seed=1664525 &* seed &+ 1013904223;return Double(seed)/Double(UInt32.max)*2-1}
        func add(time:Double,kind:PercussionKind){
            let start=Int(time*Double(rate));var phase=0.0,previousNoise=0.0
            for i in 0..<1600 where start+i<pcm.count{
                let t=Double(i)/Double(rate),n=noise(),value:Double
                switch kind{
                case .kick:
                    let frequency=Double(variant==2 ? 65 : 48)+85*exp(-t/0.012)
                    phase += 2*Double.pi*frequency/Double(rate)
                    value=0.72*sin(phase)*exp(-t/0.045)+0.16*n*exp(-t/0.0015)
                case .snare:
                    // Strong low body deliberately challenges bass-first classification.
                    let body=0.65*sin(2*Double.pi*Double(variant==1 ? 165 : 125)*t)*exp(-t/0.045)
                    let delay=variant==2 ? 0.006 : 0.003
                    let snap=t<delay ? 0 : 0.42*n*exp(-(t-delay)/0.027)
                    value=body+snap
                case .hat:
                    value=0.48*(n-previousNoise)*exp(-t/0.009);previousNoise=n
                }
                pcm[start+i] += Float(drumLevel*value)
            }
            events.append(DrumEvent(time:time,kind:kind))
        }
        for bar in 0..<4{
            let t=0.5+Double(bar)*2
            for offset in [0.0,0.75,0.875,1.5]{add(time:t+offset,kind:.kick)}
            for offset in [0.5,1.25]{add(time:t+offset,kind:.snare)}
            for offset in [0.25,1.0,1.75]{add(time:t+offset,kind:.hat)}
        }
        return(pcm.map{Float(overall)*$0},events.sorted{$0.time<$1.time})
    }
    static func score(expected:[DrumEvent],detected:[DrumEvent])->(matched:Int,correct:Int,falseHits:Int,matrix:String,latencies:[Double]){
        let expected=expected.sorted{$0.time<$1.time},detected=detected.sorted{$0.time<$1.time}
        var i=0,j=0,matched=0,correct=0,counts=[String:Int](),latencies:[Double]=[]
        while i<expected.count,j<detected.count{
            let delta=detected[j].time-expected[i].time
            if delta < -0.08{j += 1}else if delta>0.08{i += 1}else{
                matched += 1;latencies.append(delta);if expected[i].kind==detected[j].kind{correct += 1}
                counts[expected[i].kind.rawValue+">"+detected[j].kind.rawValue,default:0] += 1;i += 1;j += 1
            }
        }
        return(matched,correct,detected.count-matched,counts.keys.sorted().map{"\($0):\(counts[$0]!)"}.joined(separator:","),latencies.sorted())
    }
}
