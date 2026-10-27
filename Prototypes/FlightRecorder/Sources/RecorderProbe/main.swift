import Foundation
import FlightRecorder

let args = CommandLine.arguments
func option(_ name: String) -> String? { guard let i = args.firstIndex(of:name), i+1 < args.count else { return nil }; return args[i+1] }
guard let path = option("--output") else { fputs("RecorderProbe --output NEW_DIRECTORY [--events 20000] [--abrupt]\n",stderr); exit(2) }
let root = URL(fileURLWithPath:path,isDirectory:true)
let total = min(500_000,max(1,Int(option("--events") ?? "20000") ?? 20000))
let identity = RecorderIdentity(bundleID:"test.recorder.probe",version:"fixture",build:"1")
var config = RecorderConfiguration(); config.maxPending = 512
let recorder = FlightRecorder(root:root,identity:identity,configuration:config,coverage:["synthetic benchmark; no source chat content"])
_ = recorder.flush(timeout:5)
let baselineStart = DispatchTime.now().uptimeNanoseconds
var accumulator = 0.0
for i in 0..<total { accumulator += Double(i % 100) * 0.5 }
let baseline = Double(DispatchTime.now().uptimeNanoseconds-baselineStart)/1_000_000
var timings = [Double](); timings.reserveCapacity(total)
let before = RecorderMetrics.sample(), start = DispatchTime.now().uptimeNanoseconds
for i in 0..<total {
    let t = DispatchTime.now().uptimeNanoseconds
    recorder.record(i % 4 == 0 ? "navigation.back" : "viewport.sample",fields:["chat_id":.text("synthetic-chat"),"x":.number(Double(i % 500)),"y":.number(Double(i % 800)),"width":.number(940),"height":.number(650),"zoom":.number(1.1),"rows":.integer(1252)])
    timings.append(Double(DispatchTime.now().uptimeNanoseconds-t)/1000)
    // Representative UI bursts (120 events/s), plus an intentionally overloaded run via --burst.
    if !args.contains("--burst") { Thread.sleep(forTimeInterval:1.0/120) }
}
let enqueueMS = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
let flushed = recorder.flush(timeout:10)
if args.contains("--abrupt") { print(identity.session); fflush(stdout); _exit(86) }
let closed = recorder.close(timeout:10)
timings.sort()
struct Result: Encodable {
    let session: String, synthetic: Bool
    let events: Int, baselineLoopMS: Double, loopMS: Double, enqueueMedianUS: Double, enqueueP99US: Double
    let flushed: Bool, closed: Bool, status: RecorderStatus
    let resourcesBefore: [String:DiagnosticValue], resourcesAfter: [String:DiagnosticValue]
    let accumulator: Double
}
let result = Result(session:identity.session,synthetic:true,events:total,baselineLoopMS:baseline,loopMS:enqueueMS,enqueueMedianUS:timings[timings.count/2],enqueueP99US:timings[min(timings.count-1,Int(Double(timings.count)*0.99))],flushed:flushed,closed:closed,status:recorder.status,resourcesBefore:before,resourcesAfter:RecorderMetrics.sample(),accumulator:accumulator)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
print(String(decoding:try encoder.encode(result),as:UTF8.self))
