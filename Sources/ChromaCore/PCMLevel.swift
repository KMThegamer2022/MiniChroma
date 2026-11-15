import Foundation
public enum PCMLevel{
    public static func sample(_ bytes:UnsafeRawBufferPointer,index:Int,bits:UInt32,isBigEndian:Bool)->Double?{
        guard index>=0,bits==32 || bits==64 else{return nil}
        let width=Int(bits/8),offset=index*Int(bits/8)
        guard offset+width<=bytes.count else{return nil}
        let value:Double
        if bits==32{let raw=bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self);value=Double(Float(bitPattern:isBigEndian ? raw.byteSwapped : raw))}
        else{let raw=bytes.loadUnaligned(fromByteOffset:offset,as:UInt64.self);value=Double(bitPattern:isBigEndian ? raw.byteSwapped : raw)}
        return value.isFinite ? min(1,max(-1,value)) : nil
    }
    public static func energy(_ bytes:UnsafeRawBufferPointer,bits:UInt32,isFloat:Bool,isBigEndian:Bool)->(sum:Double,count:Int)?{
        guard isFloat,bits==32 || bits==64 else{return nil}
        let width=Int(bits/8);guard bytes.count%width==0 else{return nil}
        var sum=0.0,count=0
        for offset in stride(from:0,to:bytes.count,by:width){
            let value:Double
            if bits==32{let raw=bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self);value=Double(Float(bitPattern:isBigEndian ? raw.byteSwapped : raw))}
            else{let raw=bytes.loadUnaligned(fromByteOffset:offset,as:UInt64.self);value=Double(bitPattern:isBigEndian ? raw.byteSwapped : raw)}
            if value.isFinite{let sample=min(1,max(-1,value));sum += sample*sample;count += 1}
        }
        return count>0 ? (sum,count) : nil
    }
}
