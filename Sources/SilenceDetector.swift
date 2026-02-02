import Foundation
import AVFoundation
import Accelerate

/// Detects silence segments in audio/video files
class SilenceDetector {
    
    struct SilenceSegment: Identifiable, Equatable {
        let id = UUID()
        let startTime: Double  // seconds
        let endTime: Double    // seconds
        
        var duration: Double { endTime - startTime }
        
        var startTimecode: String { formatTime(startTime) }
        var endTimecode: String { formatTime(endTime) }
        
        private func formatTime(_ seconds: Double) -> String {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            let frames = Int((seconds.truncatingRemainder(dividingBy: 1)) * 24)
            return String(format: "%02d:%02d:%02d", mins, secs, frames)
        }
    }
    
    struct DetectionSettings {
        var silenceThresholdDB: Float = -40.0   // dB threshold for silence
        var minimumSilenceDuration: Double = 0.5 // minimum silence duration in seconds
        var paddingDuration: Double = 0.1        // keep this much before/after speech
    }
    
    private var settings: DetectionSettings
    
    init(settings: DetectionSettings = DetectionSettings()) {
        self.settings = settings
    }
    
    // MARK: - Public Methods
    
    /// Analyze audio file and return silence segments
    func detectSilence(in url: URL) async throws -> [SilenceSegment] {
        let asset = AVAsset(url: url)
        
        // Get audio track
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SilenceDetectionError.noAudioTrack
        }
        
        // Get duration
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        // Read audio samples
        let audioLevels = try await extractAudioLevels(from: audioTrack, duration: duration)
        
        // Find silence segments
        let segments = findSilenceSegments(in: audioLevels, totalDuration: durationSeconds)
        
        return segments
    }
    
    /// Analyze video file's audio track
    func detectSilenceInVideo(at path: String) async throws -> [SilenceSegment] {
        let url = URL(fileURLWithPath: path)
        return try await detectSilence(in: url)
    }
    
    /// Calculate total silence duration
    func totalSilenceDuration(in segments: [SilenceSegment]) -> Double {
        segments.reduce(0) { $0 + $1.duration }
    }
    
    /// Update detection settings
    func updateSettings(_ newSettings: DetectionSettings) {
        self.settings = newSettings
    }
    
    // MARK: - Private Methods
    
    private func extractAudioLevels(from track: AVAssetTrack, duration: CMTime) async throws -> [Float] {
        let asset = track.asset!
        
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw SilenceDetectionError.readerCreationFailed
        }
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(readerOutput)
        
        guard reader.startReading() else {
            throw SilenceDetectionError.readingFailed
        }
        
        var audioLevels: [Float] = []
        let samplesPerLevel = 4410  // 0.1 second at 44100Hz
        var sampleBuffer: [Int16] = []
        
        while let buffer = readerOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            
            if let data = dataPointer {
                let int16Pointer = UnsafeRawPointer(data).bindMemory(to: Int16.self, capacity: length / 2)
                let int16Buffer = UnsafeBufferPointer(start: int16Pointer, count: length / 2)
                sampleBuffer.append(contentsOf: int16Buffer)
                
                // Process in chunks
                while sampleBuffer.count >= samplesPerLevel {
                    let chunk = Array(sampleBuffer.prefix(samplesPerLevel))
                    sampleBuffer.removeFirst(samplesPerLevel)
                    
                    let level = calculateRMSLevel(chunk)
                    audioLevels.append(level)
                }
            }
            
            CMSampleBufferInvalidate(buffer)
        }
        
        // Process remaining samples
        if !sampleBuffer.isEmpty {
            let level = calculateRMSLevel(sampleBuffer)
            audioLevels.append(level)
        }
        
        return audioLevels
    }
    
    private func calculateRMSLevel(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return -100 }
        
        var floatSamples = [Float](repeating: 0, count: samples.count)
        vDSP_vflt16(samples, 1, &floatSamples, 1, vDSP_Length(samples.count))
        
        // Normalize to -1...1
        var divisor: Float = 32768.0
        vDSP_vsdiv(floatSamples, 1, &divisor, &floatSamples, 1, vDSP_Length(samples.count))
        
        // Calculate RMS
        var meanSquare: Float = 0
        vDSP_measqv(floatSamples, 1, &meanSquare, vDSP_Length(samples.count))
        
        let rms = sqrt(meanSquare)
        
        // Convert to dB
        let db = 20 * log10(max(rms, 0.0000001))
        return db
    }
    
    private func findSilenceSegments(in levels: [Float], totalDuration: Double) -> [SilenceSegment] {
        let timePerLevel = 0.1  // 100ms per level reading
        let minLevelsForSilence = Int(settings.minimumSilenceDuration / timePerLevel)
        let paddingLevels = Int(settings.paddingDuration / timePerLevel)
        
        var segments: [SilenceSegment] = []
        var silenceStart: Int? = nil
        
        for (index, level) in levels.enumerated() {
            let isSilent = level < settings.silenceThresholdDB
            
            if isSilent {
                if silenceStart == nil {
                    silenceStart = index
                }
            } else {
                if let start = silenceStart {
                    let silenceLength = index - start
                    
                    if silenceLength >= minLevelsForSilence {
                        // Add padding
                        let adjustedStart = max(0, start + paddingLevels)
                        let adjustedEnd = min(levels.count - 1, index - paddingLevels)
                        
                        if adjustedEnd > adjustedStart {
                            let segment = SilenceSegment(
                                startTime: Double(adjustedStart) * timePerLevel,
                                endTime: Double(adjustedEnd) * timePerLevel
                            )
                            segments.append(segment)
                        }
                    }
                    silenceStart = nil
                }
            }
        }
        
        // Handle silence at the end
        if let start = silenceStart {
            let silenceLength = levels.count - start
            if silenceLength >= minLevelsForSilence {
                let adjustedStart = max(0, start + paddingLevels)
                let segment = SilenceSegment(
                    startTime: Double(adjustedStart) * timePerLevel,
                    endTime: totalDuration
                )
                segments.append(segment)
            }
        }
        
        return segments
    }
}

// MARK: - Errors

enum SilenceDetectionError: Error, LocalizedError {
    case noAudioTrack
    case readerCreationFailed
    case readingFailed
    case invalidFile
    
    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "لا يوجد مسار صوتي في الملف"
        case .readerCreationFailed:
            return "فشل في قراءة الملف الصوتي"
        case .readingFailed:
            return "فشل في معالجة الصوت"
        case .invalidFile:
            return "ملف غير صالح"
        }
    }
}
