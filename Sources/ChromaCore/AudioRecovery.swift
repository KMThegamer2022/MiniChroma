import Foundation

/// Five capture restarts per interrupted episode, with an increasing retry delay.
/// A fresh sample resets the budget; Apply and wake create a fresh episode.
public struct AudioRecovery:Sendable {
    private var lastFresh:Double
    private var nextAttempt:Double
    public private(set) var attempts=0
    public var exhausted:Bool{attempts>=5}
    public init(now:Double){lastFresh=now;nextAttempt=now}
    public mutating func shouldRestart(now:Double,hasSample:Bool,failed:Bool)->Bool{
        if hasSample && !failed{lastFresh=now;attempts=0;nextAttempt=now;return false}
        guard !exhausted,now>=nextAttempt,(failed || now-lastFresh>=2)else{return false}
        attempts += 1;nextAttempt=now+min(30,pow(2,Double(attempts-1)));return true
    }
    public mutating func didRestart(now:Double){lastFresh=now;nextAttempt=max(nextAttempt,now+2)}
}
