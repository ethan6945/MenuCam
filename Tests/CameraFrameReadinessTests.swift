import Foundation
@main struct Tests {
 static func main() {
  var policy=CameraFrameReadiness()
  for i in 0..<30 { precondition(!policy.accepts(luminance:0,now:Double(i)/30,exposureAdjusting:false)) }
  precondition(policy.accepts(luminance:0.25,now:1.3,exposureAdjusting:true))
  var stable=CameraFrameReadiness()
  for i in 0..<10 { precondition(!stable.accepts(luminance:0.1,now:Double(i)/30,exposureAdjusting:false)) }
  precondition(stable.accepts(luminance:0.1,now:0.4,exposureAdjusting:false))
  precondition(!CameraFrameReadiness.isBlack(0.01))
  print("PASS: startup black frames rejected, stable exposure accepted, bounded exposure settling, real low-light frames preserved")
 }
}
