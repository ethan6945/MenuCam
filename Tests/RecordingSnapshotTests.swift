import Foundation
import AVFoundation
import CoreImage

@main struct RecordingSnapshotTests {
    static func main() throws {
        let host = "127.0.0.1"
        let root=URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MenuCam-livePhoto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file=root.appendingPathComponent("continuous.mov")
        let queue=DispatchQueue(label:"MenuCam.testVideo")
        let writer=AdaptiveWriter(queue:queue), server=RemoteServer(port:18772)
        var started:TimeInterval?, starts=0, finishes=0, index=0
        writer.onStart={_ in starts += 1; started=ProcessInfo.processInfo.systemUptime}
        writer.onFinish={_,error in precondition(error == nil);finishes += 1}
        server.snapshotHandler={completion in queue.async {
            writer.requestSnapshot{result in switch result {
            case .success(let data):completion(200,data)
            case .failure:completion(503,nil)
            }}
        }}
        server.start(directory:root.appendingPathComponent("keys")){_ in queue.sync {
            (200,["recording":started != nil && finishes == 0,"elapsed":started.map{Int(ProcessInfo.processInfo.systemUptime-$0)} ?? 0])
        }}
        let timer=DispatchSource.makeTimerSource(queue:queue)
        queue.sync{writer.begin(file:file)}
        timer.schedule(deadline:.now(),repeating:1.0/30)
        timer.setEventHandler{
            var buffer:CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil,1280,720,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer)==kCVReturnSuccess)
            let pixels=buffer!;CVPixelBufferLockBaseAddress(pixels,[])
            memset(CVPixelBufferGetBaseAddress(pixels)!,Int32(80+(index%60)),CVPixelBufferGetBytesPerRow(pixels)*720)
            CVPixelBufferUnlockBaseAddress(pixels,[])
            var desc:CMVideoFormatDescription?;CMVideoFormatDescriptionCreateForImageBuffer(allocator:nil,imageBuffer:pixels,formatDescriptionOut:&desc)
            var stamp=CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),presentationTimeStamp:CMTime(value:Int64(index),timescale:30),decodeTimeStamp:.invalid)
            var sample:CMSampleBuffer?;CMSampleBufferCreateReadyWithImageBuffer(allocator:nil,imageBuffer:pixels,formatDescription:desc!,sampleTiming:&stamp,sampleBufferOut:&sample)
            writer.process(sample!);index += 1
        }
        timer.resume()
        DispatchQueue.global().asyncAfter(deadline:.now()+1){
            let client=URLSession(configuration:.ephemeral)
            func get(_ path:String)->Data {
                var request=URLRequest(url:URL(string:"http://\(host):18772/api/\(path)")!);request.setValue("Bearer "+server.accessKey,forHTTPHeaderField:"Authorization")
                let done=DispatchSemaphore(value:0);var body:Data?
                client.dataTask(with:request){data,response,error in precondition(error == nil && (response as? HTTPURLResponse)?.statusCode==200);body=data;done.signal()}.resume()
                precondition(done.wait(timeout:.now()+5) == .success);return body!
            }
            let before=try! JSONSerialization.jsonObject(with:get("status")) as! [String:Any]
            for _ in 0..<4 {
                let photo=get("snapshot");guard let image=CIImage(data:photo) else {fatalError("Invalid JPEG")}
                precondition(image.extent.width==960 && image.extent.height==540)
                let stillRunning=queue.sync{starts==1 && finishes==0}
                precondition(stillRunning,"Photo interrupted or restarted recording")
                Thread.sleep(forTimeInterval:0.5)
            }
            let after=try! JSONSerialization.jsonObject(with:get("status")) as! [String:Any]
            precondition(after["recording"] as? Bool==true)
            precondition((after["elapsed"] as! Int)>(before["elapsed"] as! Int))
            queue.async{
                timer.cancel();let expected=Double(index)/30
                writer.onFinish={_,error in
                    precondition(error == nil && starts==1)
                    let asset=AVURLAsset(url:file), duration=CMTimeGetSeconds(asset.duration)
                    precondition(abs(duration-expected)<0.2,"Video duration lost during photos")
                    try? FileManager.default.removeItem(at:root)
                    print("PASS: four authenticated live photos during one continuous MOV, no restart/finish during photos, timer increases, final video duration intact")
                    exit(0)
                }
                writer.finish()
            }
        }
        RunLoop.main.run()
    }
}
