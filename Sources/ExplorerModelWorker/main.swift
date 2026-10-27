import Foundation
import Darwin
import ModelSupport

final class ParentLines {
    private var buffer=Data()
    func next() throws -> Data? {
        while true {
            if let end=buffer.firstIndex(of:10){let value=Data(buffer[..<end]);buffer.removeSubrange(...end);return value}
            var chunk=[UInt8](repeating:0,count:4096)
            let count=read(STDIN_FILENO,&chunk,chunk.count)
            if count==0{return nil}
            if count<0{if errno==EINTR{continue};throw LabelFailure("The parent connection closed.")}
            guard buffer.count+count<=32_768 else{throw LabelFailure("The parent request exceeded its bounded input.")}
            buffer.append(contentsOf:chunk.prefix(count))
        }
    }
}
let outputLock=NSLock()
func emit(_ event:LabelWorkerEvent){
    guard let data=try? JSONEncoder().encode(event) else{return}
    outputLock.lock();defer{outputLock.unlock()}
    try? FileHandle.standardOutput.write(contentsOf:data+Data([10]))
}
signal(SIGPIPE,SIG_IGN)
let lines=ParentLines()
do {
    guard let raw=try lines.next() else{exit(2)}
    let request=try JSONDecoder().decode(LabelWorkerRequest.self,from:raw)
    try request.validate()
    let cancellation=LabelCancellation()
    signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN)
    let signalQueue=DispatchQueue(label:"explorer.model-lifetime",qos:.utility,autoreleaseFrequency:.workItem)
    let terminate=DispatchSource.makeSignalSource(signal:SIGTERM,queue:signalQueue)
    terminate.setEventHandler{cancellation.cancel()};terminate.resume()
    let interrupt=DispatchSource.makeSignalSource(signal:SIGINT,queue:signalQueue)
    interrupt.setEventHandler{cancellation.cancel()};interrupt.resume()
    DispatchQueue.global(qos:.utility).async{
        do{while let data=try lines.next(){if (try? JSONSerialization.jsonObject(with:data) as? [String:Any])?["cancel"] as? Bool==true{cancellation.cancel()}}}catch{}
        cancellation.cancel() // parent exit/crash also stops the owned request
    }
    do {
        try cancellation.check()
        emit(LabelWorkerEvent(kind:"progress",jobID:request.jobID,message:"Preparing one bounded, manual label request…"))
        let text:String,model:String,effort:String
        switch request.provider{
        case .local:text=try runLocal(request,cancellation:cancellation,emit:emit);model=request.localModel;effort="disabled"
        case .luna:let result=try runLuna(request,cancellation:cancellation,emit:emit);text=result.0;model=LabelPolicy.cloudModel;effort=result.1
        }
        try cancellation.check()
        emit(LabelWorkerEvent(kind:"result",jobID:request.jobID,label:text,model:model,effort:effort))
        exit(0)
    }catch{
        emit(LabelWorkerEvent(kind:cancellation.cancelled ? "cancelled":"error",jobID:request.jobID,message:error.localizedDescription))
        exit(cancellation.cancelled ? 130:1)
    }
}catch{
    emit(LabelWorkerEvent(kind:"error",jobID:"",message:"Invalid bounded label-worker request."));exit(2)
}
