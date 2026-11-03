import Foundation
import USBBridge

public struct TemperatureReading:Sendable {
    public let celsius:Double
    public let key:String
    public let sampledAt:Date
    public var source:String{"AppleSMC · hottest M4 CPU core · \(key) (experimental)"}
    public static func decode(type:UInt32,bytes:[UInt8])->Double?{
        let value:Double
        if type == 0x666c7420,bytes.count == 4{
            let bits=UInt32(bytes[0]) | UInt32(bytes[1])<<8 | UInt32(bytes[2])<<16 | UInt32(bytes[3])<<24
            value=Double(Float(bitPattern:bits))
        }else if type == 0x73703738,bytes.count == 2{
            value=Double(Int16(bitPattern:UInt16(bytes[0])<<8 | UInt16(bytes[1])))/256
        }else{return nil}
        return value.isFinite && (1...125).contains(value) ? value : nil
    }
    public static func hottest(_ values:[String:Double])->TemperatureReading?{
        guard let pair=values.filter({$0.value.isFinite && (1...125).contains($0.value)}).max(by:{$0.value<$1.value})else{return nil}
        return TemperatureReading(celsius:pair.value,key:pair.key,sampledAt:Date())
    }
}

public actor CPUTemperature {
    private var cached:TemperatureReading?
    private var lastAttempt=Date.distantPast
    public init(){}
    public func diagnostics()->[String]{
        var lines:[String]=[]
        for key in ["Te05","Te0S","Te09","Te0H","Tp01","Tp05","Tp09","Tp0D"]{
            var bytes=[UInt8](repeating:0,count:32),type:UInt32=0,length:UInt32=0
            let result=key.withCString{mc_smc_read($0,&bytes,&type,&length)}
            lines.append(String(format:"%@ result=0x%08x type=0x%08x size=%d bytes=%@",key,result,type,length,bytes.prefix(Int(min(32,length))).map{String(format:"%02x",$0)}.joined()))
        }
        return lines
    }
    public func read()->TemperatureReading?{
        if Date().timeIntervalSince(lastAttempt)<1{return cached}
        lastAttempt=Date()
        var size=0
        guard sysctlbyname("machdep.cpu.brand_string",nil,&size,nil,0)==0,size>0 else{return nil}
        var brand=[CChar](repeating:0,count:size)
        guard sysctlbyname("machdep.cpu.brand_string",&brand,&size,nil,0)==0,String(cString:brand).hasPrefix("Apple M4")else{return nil}
        var values:[String:Double]=[:]
        for key in ["Te05","Te0S","Te09","Te0H","Tp01","Tp05","Tp09","Tp0D","Tp0V","Tp0Y","Tp0b","Tp0e"]{
            var bytes=[UInt8](repeating:0,count:32),type:UInt32=0,length:UInt32=0
            let result=key.withCString{pointer in mc_smc_read(pointer,&bytes,&type,&length)}
            if result==0,length<=32,let value=TemperatureReading.decode(type:type,bytes:Array(bytes.prefix(Int(length)))){values[key]=value}
        }
        cached=TemperatureReading.hottest(values);return cached
    }
}
