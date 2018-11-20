import Foundation
import AVFoundation

public class Stream: NSObject, ImageSource, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public let targets = TargetContainer()
    let videoOutput:AVCaptureVideoDataOutput!
    var audioOutput:AVCaptureAudioDataOutput?
    var supportsFullYUVRange:Bool = false
    var yuvConversionShader:ShaderProgram?
    let frameRenderingSemaphore = DispatchSemaphore(value:1)
    let StreamProcessingQueue = DispatchQueue.global()
    let audioProcessingQueue = DispatchQueue.global()
    
    let framesToIgnore = 5
    var numberOfFramesCaptured = 0
    var totalFrameTimeDuringCapture:Double = 0.0
    var framesSinceLastCheck = 0
    var lastCheckTime = CFAbsoluteTimeGetCurrent()
    
    init(sessionPreset:AVCaptureSession.Preset, StreamDevice:AVCaptureDevice? = nil) {
        self.yuvConversionShader = nil

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = false
        
        supportsFullYUVRange = false
        let supportedPixelFormats = videoOutput.availableVideoPixelFormatTypes
        for currentPixelFormat in supportedPixelFormats {
            if ((currentPixelFormat as NSNumber).int32Value == Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
                supportsFullYUVRange = true
            }
        }
        
        yuvConversionShader = crashOnShaderCompileFailure("Stream"){try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader:YUVConversionVideoRangeFragmentShader)}
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:NSNumber(value:Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))]
        
        super.init()
        
        videoOutput.setSampleBufferDelegate(self, queue:StreamProcessingQueue)
    }
    
    deinit {
        sharedImageProcessingContext.runOperationSynchronously{
            self.stopCapture()
            self.videoOutput?.setSampleBufferDelegate(nil, queue:nil)
            self.audioOutput?.setSampleBufferDelegate(nil, queue:nil)
        }
    }
    
    public func captureOutput(pixelBuffer: CVPixelBuffer, currentTime: CMTime) {
        guard (frameRenderingSemaphore.wait(timeout:DispatchTime.now()) == DispatchTimeoutResult.success) else { return }
    
        let StreamFrame = pixelBuffer
        let bufferWidth = CVPixelBufferGetWidth(StreamFrame)
        let bufferHeight = CVPixelBufferGetHeight(StreamFrame)

        CVPixelBufferLockBaseAddress(StreamFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
        sharedImageProcessingContext.runOperationAsynchronously{
            let StreamFramebuffer:Framebuffer
            
            let luminanceFramebuffer:Framebuffer
            let chrominanceFramebuffer:Framebuffer
            if sharedImageProcessingContext.supportsTextureCaches() {
                var luminanceTextureRef:CVOpenGLESTexture? = nil
                let _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, StreamFrame, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), 0, &luminanceTextureRef)
                let luminanceTexture = CVOpenGLESTextureGetName(luminanceTextureRef!)
                glActiveTexture(GLenum(GL_TEXTURE4))
                glBindTexture(GLenum(GL_TEXTURE_2D), luminanceTexture)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
                luminanceFramebuffer = try! Framebuffer(context:sharedImageProcessingContext, orientation:ImageOrientation.portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:true, overriddenTexture:luminanceTexture)
                
                var chrominanceTextureRef:CVOpenGLESTexture? = nil
                let _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, StreamFrame, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), 1, &chrominanceTextureRef)
                let chrominanceTexture = CVOpenGLESTextureGetName(chrominanceTextureRef!)
                glActiveTexture(GLenum(GL_TEXTURE5))
                glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceTexture)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
                chrominanceFramebuffer = try! Framebuffer(context:sharedImageProcessingContext, orientation:ImageOrientation.portrait, size:GLSize(width:GLint(bufferWidth / 2), height:GLint(bufferHeight / 2)), textureOnly:true, overriddenTexture:chrominanceTexture)
            } else {
                glActiveTexture(GLenum(GL_TEXTURE4))
                luminanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:ImageOrientation.portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:true)
                luminanceFramebuffer.lock()
                
                glBindTexture(GLenum(GL_TEXTURE_2D), luminanceFramebuffer.texture)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), 0, GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(StreamFrame, 0))
                
                glActiveTexture(GLenum(GL_TEXTURE5))
                chrominanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:ImageOrientation.portrait, size:GLSize(width:GLint(bufferWidth / 2), height:GLint(bufferHeight / 2)), textureOnly:true)
                chrominanceFramebuffer.lock()
                glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceFramebuffer.texture)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), 0, GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(StreamFrame, 1))
            }
            
            StreamFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.portrait, size:luminanceFramebuffer.sizeForTargetOrientation(.portrait), textureOnly:false)
            
            let conversionMatrix:Matrix3x3
            if (self.supportsFullYUVRange) {
                conversionMatrix = colorConversionMatrix601FullRangeDefault
            } else {
                conversionMatrix = colorConversionMatrix601Default
            }
            convertYUVToRGB(shader:self.yuvConversionShader!, luminanceFramebuffer:luminanceFramebuffer, chrominanceFramebuffer:chrominanceFramebuffer, resultFramebuffer:StreamFramebuffer, colorConversionMatrix:conversionMatrix)
            
            CVPixelBufferUnlockBaseAddress(StreamFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
            
            StreamFramebuffer.timingStyle = .videoFrame(timestamp:Timestamp(currentTime))
            self.updateTargetsWithFramebuffer(StreamFramebuffer)

            self.frameRenderingSemaphore.signal()
        }
    }
    
    public func startCapture() {
        self.numberOfFramesCaptured = 0
        self.totalFrameTimeDuringCapture = 0
    }
    
    public func stopCapture() {

    }
    
    public func transmitPreviousImage(to target:ImageConsumer, atIndex:UInt) {
        // Not needed for Stream inputs
    }

}
