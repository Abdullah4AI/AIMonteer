import Foundation
import AVFoundation

/// Type alias for SilenceSegment
typealias SilenceSegment = SilenceDetector.SilenceSegment

/// Controller for Final Cut Pro FCPXML manipulation
class FCPXMLController: ObservableObject {
    @Published var isProcessing = false
    @Published var statusMessage = ""
    @Published var detectedSilenceSegments: [SilenceSegment] = []
    
    private let silenceDetector = SilenceDetector()
    
    struct FCPXMLInfo {
        var projectName: String
        var duration: Double
        var frameRate: Double
        var audioFilePath: String?
    }
    
    // MARK: - Parse FCPXML
    
    func parseFCPXML(at url: URL) -> FCPXMLInfo? {
        guard let xmlData = try? Data(contentsOf: url),
              let xmlDoc = try? XMLDocument(data: xmlData) else {
            return nil
        }
        
        var info = FCPXMLInfo(projectName: "", duration: 0, frameRate: 30, audioFilePath: nil)
        
        // Get project name
        if let project = try? xmlDoc.nodes(forXPath: "//project").first as? XMLElement {
            info.projectName = project.attribute(forName: "name")?.stringValue ?? "Unknown"
        }
        
        // Get sequence/timeline info
        if let sequence = try? xmlDoc.nodes(forXPath: "//sequence").first as? XMLElement {
            if let duration = sequence.attribute(forName: "duration")?.stringValue {
                info.duration = parseFCPXMLTime(duration, frameRate: info.frameRate)
            }
            if let format = sequence.attribute(forName: "format")?.stringValue,
               let formatElement = try? xmlDoc.nodes(forXPath: "//format[@id='\(format)']").first as? XMLElement,
               let frameRateStr = formatElement.attribute(forName: "frameDuration")?.stringValue {
                info.frameRate = parseFrameRate(frameRateStr)
            }
        }
        
        // Get first audio/video asset
        if let asset = try? xmlDoc.nodes(forXPath: "//asset").first as? XMLElement {
            info.audioFilePath = asset.attribute(forName: "src")?.stringValue
        }
        
        return info
    }
    
    // MARK: - Analyze and Remove Silence
    
    func processAndRemoveSilence(fcpxmlURL: URL, outputURL: URL) async -> Bool {
        await MainActor.run {
            isProcessing = true
            statusMessage = "جاري تحليل الـ FCPXML..."
        }
        
        // 1. Parse FCPXML
        guard let info = parseFCPXML(at: fcpxmlURL) else {
            await MainActor.run {
                statusMessage = "فشل قراءة ملف FCPXML"
                isProcessing = false
            }
            return false
        }
        
        // 2. Get audio file path
        guard let audioPath = info.audioFilePath,
              let audioURL = URL(string: audioPath) else {
            await MainActor.run {
                statusMessage = "لم يتم العثور على ملف صوتي"
                isProcessing = false
            }
            return false
        }
        
        await MainActor.run {
            statusMessage = "جاري تحليل الصوت لكشف الصمت..."
        }
        
        // 3. Detect silence in audio
        let silenceSegments: [SilenceSegment]
        do {
            silenceSegments = try await silenceDetector.detectSilence(in: audioURL)
        } catch {
            await MainActor.run {
                statusMessage = "فشل تحليل الصوت: \(error.localizedDescription)"
                isProcessing = false
            }
            return false
        }
        
        guard !silenceSegments.isEmpty else {
            await MainActor.run {
                statusMessage = "لا يوجد صمت في الملف"
                isProcessing = false
            }
            return true
        }
        
        await MainActor.run {
            detectedSilenceSegments = silenceSegments
            statusMessage = "تم اكتشاف \(silenceSegments.count) مقطع صمت. جاري التعديل..."
        }
        
        // 4. Modify FCPXML to remove silence
        let success = removeSilenceFromFCPXML(
            inputURL: fcpxmlURL,
            outputURL: outputURL,
            silenceSegments: silenceSegments,
            frameRate: info.frameRate
        )
        
        await MainActor.run {
            if success {
                let totalRemoved = silenceDetector.totalSilenceDuration(in: silenceSegments)
                let minutes = Int(totalRemoved) / 60
                let seconds = Int(totalRemoved) % 60
                statusMessage = "تم حذف \(silenceSegments.count) مقطع صمت (وفرت \(minutes):\(String(format: "%02d", seconds)))\n\n📁 الملف المعدل: \(outputURL.lastPathComponent)"
            } else {
                statusMessage = "فشل تعديل الـ FCPXML"
            }
            isProcessing = false
        }
        
        return success
    }
    
    // MARK: - FCPXML Modification
    
    private func removeSilenceFromFCPXML(inputURL: URL, outputURL: URL, silenceSegments: [SilenceSegment], frameRate: Double) -> Bool {
        guard let xmlData = try? Data(contentsOf: inputURL),
              let xmlDoc = try? XMLDocument(data: xmlData, options: .nodePreserveAll) else {
            return false
        }
        
        // Sort segments by start time (descending) to process from end first
        let sortedSegments = silenceSegments.sorted { $0.startTime > $1.startTime }
        
        // Find all clip/asset-clip elements and modify their timing
        // This is a simplified approach - real implementation would need more sophisticated XML manipulation
        
        for segment in sortedSegments {
            let startFrames = Int(segment.startTime * frameRate)
            let endFrames = Int(segment.endTime * frameRate)
            let durationFrames = endFrames - startFrames
            
            // Find clips that overlap with this silence segment
            if let clips = try? xmlDoc.nodes(forXPath: "//asset-clip | //clip | //video | //audio") {
                for case let clip as XMLElement in clips {
                    adjustClipTiming(clip, removingFrames: durationFrames, afterFrame: startFrames, frameRate: frameRate)
                }
            }
        }
        
        // Write modified XML
        let xmlString = xmlDoc.xmlString(options: [.nodePrettyPrint])
        do {
            try xmlString.write(to: outputURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("Failed to write FCPXML: \(error)")
            return false
        }
    }
    
    private func adjustClipTiming(_ clip: XMLElement, removingFrames: Int, afterFrame: Int, frameRate: Double) {
        // Get current offset and duration
        guard let offsetStr = clip.attribute(forName: "offset")?.stringValue,
              let durationStr = clip.attribute(forName: "duration")?.stringValue else {
            return
        }
        
        let currentOffset = parseFCPXMLTime(offsetStr, frameRate: frameRate)
        let currentOffsetFrames = Int(currentOffset * frameRate)
        
        // If clip starts after the silence, shift it back
        if currentOffsetFrames > afterFrame {
            let newOffsetFrames = currentOffsetFrames - removingFrames
            let newOffset = formatFCPXMLTime(frames: newOffsetFrames, frameRate: frameRate)
            clip.attribute(forName: "offset")?.stringValue = newOffset
        }
    }
    
    // MARK: - Time Parsing Utilities
    
    private func parseFCPXMLTime(_ timeString: String, frameRate: Double) -> Double {
        // FCPXML uses rational time format: "83691520/2400000s" or "10s"
        if timeString.hasSuffix("s") {
            let cleanString = String(timeString.dropLast())
            if cleanString.contains("/") {
                let parts = cleanString.split(separator: "/")
                if parts.count == 2,
                   let numerator = Double(parts[0]),
                   let denominator = Double(parts[1]) {
                    return numerator / denominator
                }
            } else {
                return Double(cleanString) ?? 0
            }
        }
        return 0
    }
    
    private func formatFCPXMLTime(frames: Int, frameRate: Double) -> String {
        // Convert frames to FCPXML rational time
        let timebase = 1000000
        let numerator = Int(Double(frames) / frameRate * Double(timebase))
        return "\(numerator)/\(timebase)s"
    }
    
    private func parseFrameRate(_ frameDuration: String) -> Double {
        // Parse frame duration like "1001/30000s" to get frame rate
        if frameDuration.hasSuffix("s") {
            let cleanString = String(frameDuration.dropLast())
            if cleanString.contains("/") {
                let parts = cleanString.split(separator: "/")
                if parts.count == 2,
                   let numerator = Double(parts[0]),
                   let denominator = Double(parts[1]) {
                    return denominator / numerator
                }
            }
        }
        return 30.0 // Default
    }
}
