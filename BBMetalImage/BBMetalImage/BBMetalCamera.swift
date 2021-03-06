//
//  BBMetalCamera.swift
//  BBMetalImage
//
//  Created by Kaibo Lu on 4/8/19.
//  Copyright © 2019 Kaibo Lu. All rights reserved.
//

import AVFoundation

/// Camera capturing image and providing Metal texture
public class BBMetalCamera: NSObject {
    /// Image consumers
    public var consumers: [BBMetalImageConsumer] {
        lock.wait()
        let c = _consumers
        lock.signal()
        return c
    }
    private var _consumers: [BBMetalImageConsumer]
    
    /// A block to call before transmiting texture to image consumers
    public var willTransmitTexture: ((MTLTexture) -> Void)? {
        get {
            lock.wait()
            let w = _willTransmitTexture
            lock.signal()
            return w
        }
        set {
            lock.wait()
            _willTransmitTexture = newValue
            lock.signal()
        }
    }
    private var _willTransmitTexture: ((MTLTexture) -> Void)?
    
    /// Camera position
    public var position: AVCaptureDevice.Position { return camera.position }
    
    /// Whether to run benchmark or not.
    /// Running benchmark records frame duration.
    /// False by default.
    public var benchmark: Bool {
        get {
            lock.wait()
            let b = _benchmark
            lock.signal()
            return b
        }
        set {
            lock.wait()
            _benchmark = newValue
            lock.signal()
        }
    }
    private var _benchmark: Bool
    
    /// Average frame duration, or 0 if not valid value.
    /// To get valid value, set `benchmark` to true.
    public var averageFrameDuration: Double {
        lock.wait()
        let d = capturedFrameCount > ignoreInitialFrameCount ? totalCaptureFrameTime / Double(capturedFrameCount - ignoreInitialFrameCount) : 0
        lock.signal()
        return d
    }
    
    private var capturedFrameCount: Int
    private var totalCaptureFrameTime: Double
    private let ignoreInitialFrameCount: Int
    
    private let lock: DispatchSemaphore
    
    private var session: AVCaptureSession!
    private var camera: AVCaptureDevice!
    private var videoInput: AVCaptureDeviceInput!
    private var videoOutput: AVCaptureVideoDataOutput!
    private var videoOutputQueue: DispatchQueue!
    
    private var audioInput: AVCaptureDeviceInput!
    private var audioOutput: AVCaptureAudioDataOutput!
    private var audioOutputQueue: DispatchQueue!
    
    /// Audio consumer processing audio sample buffer.
    /// Set this property to nil (default value) if not recording audio.
    /// Set this property to a given audio consumer if recording audio.
    public var audioConsumer: BBMetalAudioConsumer? {
        get {
            lock.wait()
            let a = _audioConsumer
            lock.signal()
            return a
        }
        set {
            lock.wait()
            _audioConsumer = newValue
            if newValue != nil {
                addAudioInputAndOutput()
            } else {
                removeAudioInputAndOutput()
            }
            lock.signal()
        }
    }
    private var _audioConsumer: BBMetalAudioConsumer?
    
    #if !targetEnvironment(simulator)
    private var textureCache: CVMetalTextureCache!
    #endif
    
    public init?(sessionPreset: AVCaptureSession.Preset = .high, position: AVCaptureDevice.Position = .back) {
        _consumers = []
        _benchmark = false
        capturedFrameCount = 0
        totalCaptureFrameTime = 0
        ignoreInitialFrameCount = 5
        lock = DispatchSemaphore(value: 1)
        
        super.init()
        
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
            let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice) else { return nil }
        
        session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = sessionPreset
        
        if !session.canAddInput(videoDeviceInput) {
            session.commitConfiguration()
            return nil
        }
        
        session.addInput(videoDeviceInput)
        camera = videoDevice
        videoInput = videoDeviceInput
        
        let videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String : kCVPixelFormatType_32BGRA]
        videoOutputQueue = DispatchQueue(label: "com.Kaibo.BBMetalImage.Camera.videoOutput")
        videoDataOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if !session.canAddOutput(videoDataOutput) {
            session.commitConfiguration()
            return nil
        }
        session.addOutput(videoDataOutput)
        videoOutput = videoDataOutput
        
        guard let connection = videoDataOutput.connections.first,
            connection.isVideoOrientationSupported else {
                session.commitConfiguration()
                return nil
        }
        connection.videoOrientation = .portrait
        
        session.commitConfiguration()
        
        #if !targetEnvironment(simulator)
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, BBMetalDevice.sharedDevice, nil, &textureCache) != kCVReturnSuccess ||
            textureCache == nil {
            return nil
        }
        #endif
    }
    
    @discardableResult
    private func addAudioInputAndOutput() -> Bool {
        if audioOutput != nil { return true }
        
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        guard let audioDevice = AVCaptureDevice.default(.builtInMicrophone, for: .audio, position: .unspecified),
            let input = try? AVCaptureDeviceInput(device: audioDevice),
            session.canAddInput(input) else {
                print("Can not add audio input")
                return false
        }
        session.addInput(input)
        audioInput = input
        
        let output = AVCaptureAudioDataOutput()
        let outputQueue = DispatchQueue(label: "com.Kaibo.BBMetalImage.Camera.audioOutput")
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            _removeAudioInputAndOutput()
            print("Can not add audio output")
            return false
        }
        session.addOutput(output)
        audioOutput = output
        audioOutputQueue = outputQueue
        
        return true
    }
    
    private func removeAudioInputAndOutput() {
        session.beginConfiguration()
        _removeAudioInputAndOutput()
        session.commitConfiguration()
    }
    
    private func _removeAudioInputAndOutput() {
        if let input = audioInput {
            session.removeInput(input)
            audioInput = nil
        }
        if let output = audioOutput {
            session.removeOutput(output)
            audioOutput = nil
        }
        if audioOutputQueue != nil {
            audioOutputQueue = nil
        }
    }
    
    /// Switches camera position (back to front, or front to back)
    ///
    /// - Returns: true if succeed, or false if fail
    @discardableResult
    public func switchCameraPosition() -> Bool {
        lock.wait()
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            lock.signal()
        }
        
        var position: AVCaptureDevice.Position = .back
        if camera.position == .back { position = .front }
        
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
            let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice) else { return false }
        
        session.removeInput(videoInput)
        
        guard session.canAddInput(videoDeviceInput) else {
            session.addInput(videoInput)
            return false
        }
        session.addInput(videoDeviceInput)
        camera = videoDevice
        videoInput = videoDeviceInput
        
        guard let connection = videoOutput.connections.first,
            connection.isVideoOrientationSupported else { return false }
        connection.videoOrientation = .portrait
        
        return true
    }
    
    /// Starts capturing
    public func start() { session.startRunning() }
    
    /// Stops capturing
    public func stop() { session.stopRunning() }
    
    /// Resets benchmark record data
    public func resetBenchmark() {
        lock.wait()
        capturedFrameCount = 0
        totalCaptureFrameTime = 0
        lock.signal()
    }
}

extension BBMetalCamera: BBMetalImageSource {
    @discardableResult
    public func add<T: BBMetalImageConsumer>(consumer: T) -> T {
        lock.wait()
        _consumers.append(consumer)
        lock.signal()
        consumer.add(source: self)
        return consumer
    }
    
    public func add(consumer: BBMetalImageConsumer, at index: Int) {
        lock.wait()
        _consumers.insert(consumer, at: index)
        lock.signal()
        consumer.add(source: self)
    }
    
    public func remove(consumer: BBMetalImageConsumer) {
        lock.wait()
        if let index = _consumers.firstIndex(where: { $0 === consumer }) {
            _consumers.remove(at: index)
            lock.signal()
            consumer.remove(source: self)
        } else {
            lock.signal()
        }
    }
    
    public func removeAllConsumers() {
        lock.wait()
        let consumers = _consumers
        _consumers.removeAll()
        lock.signal()
        for consumer in consumers {
            consumer.remove(source: self)
        }
    }
}

extension BBMetalCamera: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Audio
        if output is AVCaptureAudioDataOutput,
            let consumer = audioConsumer {
            consumer.newAudioSampleBufferAvailable(sampleBuffer)
            return
        }
        
        // Video
        lock.wait()
        let consumers = _consumers
        let willTransmit = _willTransmitTexture
        let cameraPosition = camera.position
        let startTime = _benchmark ? CACurrentMediaTime() : 0
        lock.signal()
        
        guard !consumers.isEmpty,
            let texture = texture(with: sampleBuffer) else { return }
        
        willTransmit?(texture)
        let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let output = BBMetalDefaultTexture(metalTexture: texture,
                                           sampleTime: sampleTime,
                                           cameraPosition: cameraPosition)
        for consumer in consumers { consumer.newTextureAvailable(output, from: self) }
        
        // Benchmark
        if startTime != 0 {
            lock.wait()
            capturedFrameCount += 1
            if capturedFrameCount > ignoreInitialFrameCount {
                totalCaptureFrameTime += CACurrentMediaTime() - startTime
            }
            lock.signal()
        }
    }
    
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print(#function)
    }
    
    private func texture(with sampleBuffer: CMSampleBuffer) -> MTLTexture? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        #if !targetEnvironment(simulator)
        var cvMetalTextureOut: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               textureCache,
                                                               imageBuffer,
                                                               nil,
                                                               .bgra8Unorm, // camera ouput BGRA
                                                               width,
                                                               height,
                                                               0,
                                                               &cvMetalTextureOut)
        if result == kCVReturnSuccess,
            let cvMetalTexture = cvMetalTextureOut,
            let texture = CVMetalTextureGetTexture(cvMetalTexture) {
            return texture
        }
        #endif
        return nil
    }
}
