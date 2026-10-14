import AudioToolbox
import CoreMedia
import CoreVideo
import Darwin
import Foundation

/// Test-only decoded media. The caller owns wall-clock pacing and the production writer.
/// Cached images and PCM blocks are immutable; every call creates fresh sample timing.
final class SyntheticLiveMediaSource {
    static let durationSeconds = 60.0
    static let frameCount = 1800
    static let framesPerSecond: Int32 = 30
    static let audioSampleRate: Int32 = 48_000
    static let audioSamplesPerFrame = 1600

    private static let width = 854
    private static let height = 480
    private static let channels = 2
    private static let framesPerPulseCycle = 60
    private static let flashFrames = 3
    private static let audioBytesPerSampleFrame = MemoryLayout<Int16>.size * channels

    // The pool is retained and hard-limited to the two immutable images built at init.
    private let pixelPool: CVPixelBufferPool
    private let darkImage: CVPixelBuffer
    private let flashImage: CVPixelBuffer
    private let videoDescription: CMVideoFormatDescription
    private let audioDescription: CMAudioFormatDescription
    private let silentPCM: CMBlockBuffer
    private let flashPCM: [CMBlockBuffer]

    init() throws {
        var pool: CVPixelBufferPool?
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 2] as CFDictionary
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width,
            kCVPixelBufferHeightKey as String: Self.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        try Self.check(CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes,
            pixelAttributes as CFDictionary, &pool), "CVPixelBufferPoolCreate")
        guard let pool else { throw Self.invalid("pixel pool missing") }
        pixelPool = pool
        let dark = try Self.makeImage(pool: pool, level: 24)
        let flash = try Self.makeImage(pool: pool, level: 255)
        darkImage = dark
        flashImage = flash

        var videoFormat: CMVideoFormatDescription?
        try Self.check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: dark, formatDescriptionOut: &videoFormat), "CMVideoFormatDescriptionCreateForImageBuffer")
        guard let videoFormat,
              CMVideoFormatDescriptionMatchesImageBuffer(videoFormat, imageBuffer: flash) else {
            throw Self.invalid("cached images do not share a valid video format")
        }
        videoDescription = videoFormat

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(Self.audioSampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(Self.audioBytesPerSampleFrame), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(Self.audioBytesPerSampleFrame), mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 16, mReserved: 0)
        var audioFormat: CMAudioFormatDescription?
        try Self.check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &audioFormat), "CMAudioFormatDescriptionCreate")
        guard let audioFormat else { throw Self.invalid("audio format missing") }
        audioDescription = audioFormat
        silentPCM = try Self.makePCMBlock(pulseFrameOffset: nil)
        flashPCM = try (0..<Self.flashFrames).map { try Self.makePCMBlock(pulseFrameOffset: $0) }
    }

    /// Video: one BGRA image at index/30, duration 1/30.
    /// Audio: 1600 stereo PCM sample frames at the same PTS, each duration 1/48000.
    func samplePair(frameIndex: Int) throws -> (CMSampleBuffer, CMSampleBuffer) {
        guard (0..<Self.frameCount).contains(frameIndex) else {
            throw Self.invalid("frameIndex must be within 0..<1800")
        }
        let cycleFrame = frameIndex % Self.framesPerPulseCycle
        let isPulse = frameIndex >= Self.framesPerPulseCycle && cycleFrame < Self.flashFrames
        let pts = CMTime(value: Int64(frameIndex), timescale: Self.framesPerSecond)
        let frameDuration = CMTime(value: 1, timescale: Self.framesPerSecond)
        var videoTiming = CMSampleTimingInfo(duration: frameDuration,
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var videoSample: CMSampleBuffer?
        try Self.check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: isPulse ? flashImage : darkImage, formatDescription: videoDescription,
            sampleTiming: &videoTiming, sampleBufferOut: &videoSample), "CMSampleBufferCreateReadyWithImageBuffer")
        guard let videoSample else { throw Self.invalid("video sample missing") }

        var audioTiming = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Self.audioSampleRate),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = Self.audioBytesPerSampleFrame
        var audioSample: CMSampleBuffer?
        let pcm = isPulse ? flashPCM[cycleFrame] : silentPCM
        try Self.check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: pcm,
            formatDescription: audioDescription, sampleCount: Self.audioSamplesPerFrame,
            sampleTimingEntryCount: 1, sampleTimingArray: &audioTiming,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &audioSample),
            "CMSampleBufferCreateReady PCM")
        guard let audioSample else { throw Self.invalid("audio sample missing") }
        guard CMSampleBufferIsValid(videoSample), CMSampleBufferDataIsReady(videoSample),
              CMSampleBufferIsValid(audioSample), CMSampleBufferDataIsReady(audioSample),
              CMSampleBufferGetNumSamples(videoSample) == 1,
              CMSampleBufferGetNumSamples(audioSample) == Self.audioSamplesPerFrame,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(videoSample), pts) == 0,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(audioSample), pts) == 0,
              CMTimeCompare(CMSampleBufferGetDuration(videoSample), frameDuration) == 0,
              CMTimeCompare(CMSampleBufferGetDuration(audioSample), frameDuration) == 0 else {
            throw Self.invalid("sample readiness, count or shared timing mismatch")
        }
        return (videoSample, audioSample)
    }

    private static func makeImage(pool: CVPixelBufferPool, level: UInt8) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let allocation = [kCVPixelBufferPoolAllocationThresholdKey as String: 2] as CFDictionary
        try check(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,
            pool, allocation, &image), "CVPixelBufferPoolCreatePixelBufferWithAuxAttributes")
        guard let image else { throw invalid("pooled image missing") }
        let flags: CVPixelBufferLockFlags = []
        try check(CVPixelBufferLockBaseAddress(image, flags), "CVPixelBufferLockBaseAddress")
        let stride = CVPixelBufferGetBytesPerRow(image)
        let dataSize = CVPixelBufferGetDataSize(image)
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height,
              stride >= width * 4, dataSize >= stride * height,
              let base = CVPixelBufferGetBaseAddress(image) else {
            try check(CVPixelBufferUnlockBaseAddress(image, flags), "CVPixelBufferUnlockBaseAddress invalid image")
            throw invalid("BGRA image geometry or storage invalid")
        }
        memset(base, Int32(level), dataSize)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width { bytes[row * stride + column * 4 + 3] = 255 }
        }
        try check(CVPixelBufferUnlockBaseAddress(image, flags), "CVPixelBufferUnlockBaseAddress")
        return image
    }

    private static func makePCMBlock(pulseFrameOffset: Int?) throws -> CMBlockBuffer {
        var samples = [Int16](repeating: 0, count: audioSamplesPerFrame * channels)
        if let pulseFrameOffset {
            guard (0..<flashFrames).contains(pulseFrameOffset) else { throw invalid("PCM pulse offset invalid") }
            for index in 0..<audioSamplesPerFrame {
                let pulseSample = pulseFrameOffset * audioSamplesPerFrame + index
                let phase = 2 * Double.pi * 1000 * Double(pulseSample) / Double(audioSampleRate)
                let value = Int16((sin(phase) * Double(Int16.max) * 0.2).rounded())
                samples[index * channels] = value
                samples[index * channels + 1] = value
            }
        }
        let byteCount = audioSamplesPerFrame * audioBytesPerSampleFrame
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block),
            "CMBlockBufferCreateWithMemoryBlock")
        guard let block else { throw invalid("PCM block missing") }
        let copyStatus = samples.withUnsafeBufferPointer { pointer -> OSStatus in
            guard let base = pointer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: UnsafeRawPointer(base), blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount)
        }
        try check(copyStatus, "CMBlockBufferReplaceDataBytes PCM")
        guard CMBlockBufferGetDataLength(block) == byteCount else { throw invalid("PCM byte count mismatch") }
        return block
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SyntheticLiveMediaFailure(operation: operation, status: status) }
    }

    private static func invalid(_ operation: String) -> SyntheticLiveMediaFailure {
        SyntheticLiveMediaFailure(operation: operation, status: -1)
    }
}

private struct SyntheticLiveMediaFailure: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus
    var description: String { "SyntheticLiveMediaSource: \(operation) (\(status))" }
}
