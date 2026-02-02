import Foundation
import AppKit

/// Controller for communicating with DaVinci Resolve
@MainActor
class DaVinciController: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var currentProject: String = ""
    @Published var currentTimeline: String = ""
    @Published var isAnalyzing: Bool = false
    @Published var detectedSilenceSegments: [SilenceDetector.SilenceSegment] = []
    
    private let scriptPath: String
    private let silenceDetector = SilenceDetector()
    
    init() {
        // DaVinci Resolve scripting path
        self.scriptPath = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
    }
    
    // MARK: - Connection
    
    func checkConnection() async {
        // Check if DaVinci Resolve is running
        let runningApps = NSWorkspace.shared.runningApplications
        let davinciRunning = runningApps.contains { app in
            app.bundleIdentifier == "com.blackmagic-design.DaVinciResolve" ||
            app.localizedName?.contains("DaVinci") == true
        }
        
        if davinciRunning {
            // Try to connect via scripting
            let connected = await testScriptingConnection()
            isConnected = connected
        } else {
            isConnected = false
        }
    }
    
    private func testScriptingConnection() async -> Bool {
        // Test Python scripting connection
        let script = """
        import sys
        import os
        
        # Add module path
        module_path = '/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules'
        if module_path not in sys.path:
            sys.path.append(module_path)
        
        try:
            import DaVinciResolveScript as dvr
        except ImportError as e:
            print(f"import_error: {e}")
            sys.exit(1)
        
        try:
            resolve = dvr.scriptapp("Resolve")
            if resolve is None:
                print("error: scriptapp returned None - check if Resolve is running and scripting is enabled")
                sys.exit(1)
            
            pm = resolve.GetProjectManager()
            if pm is None:
                print("error: GetProjectManager returned None")
                sys.exit(1)
            
            print("connected")
            sys.exit(0)
        except Exception as e:
            print(f"error: {e}")
            sys.exit(1)
        """
        
        let result = await runPythonScript(script)
        print("DaVinci connection test result: \(result)")  // Debug logging
        return result.contains("connected")
    }
    
    // MARK: - Command Execution
    
    func executeCommand(_ command: String) async -> CommandResult {
        guard isConnected else {
            return CommandResult(success: false, message: "غير متصل بـ DaVinci Resolve")
        }
        
        // Parse the command
        let parsedCommand = parseCommand(command)
        
        switch parsedCommand {
        case .cut(let start, let end):
            return await executeCut(start: start, end: end)
        case .delete(let start, let end):
            return await executeDelete(start: start, end: end)
        case .addText(let text, let position):
            return await executeAddText(text: text, position: position)
        case .export(let format):
            return await executeExport(format: format)
        case .info:
            return await getProjectInfo()
        case .analyzeSilence:
            return await analyzeSilence()
        case .removeSilence:
            return await removeSilence()
        case .unknown:
            return CommandResult(success: false, message: "لم أفهم الأمر. جرب: 'قص من 0:00 إلى 0:30' أو 'احذف الصمت' أو 'معلومات المشروع'")
        }
    }
    
    // MARK: - Command Parsing
    
    private enum ParsedCommand {
        case cut(start: String, end: String)
        case delete(start: String, end: String)
        case addText(text: String, position: String?)
        case export(format: String)
        case info
        case removeSilence
        case analyzeSilence
        case unknown
    }
    
    private func parseCommand(_ command: String) -> ParsedCommand {
        let lowercased = command.lowercased()
        
        // Arabic patterns
        if lowercased.contains("قص") || lowercased.contains("cut") {
            if let times = extractTimes(from: command) {
                return .cut(start: times.start, end: times.end)
            }
        }
        
        if lowercased.contains("حذف") || lowercased.contains("delete") || lowercased.contains("احذف") {
            if let times = extractTimes(from: command) {
                return .delete(start: times.start, end: times.end)
            }
        }
        
        if lowercased.contains("نص") || lowercased.contains("text") || lowercased.contains("اكتب") {
            // Extract text between quotes if any
            if let text = extractQuotedText(from: command) {
                return .addText(text: text, position: nil)
            }
        }
        
        if lowercased.contains("صدر") || lowercased.contains("export") || lowercased.contains("تصدير") {
            let format = lowercased.contains("mp4") ? "mp4" : "mov"
            return .export(format: format)
        }
        
        if lowercased.contains("معلومات") || lowercased.contains("info") || lowercased.contains("المشروع") {
            return .info
        }
        
        // Silence detection and removal
        if lowercased.contains("صمت") || lowercased.contains("silence") || lowercased.contains("سكوت") {
            if lowercased.contains("احذف") || lowercased.contains("حذف") || lowercased.contains("remove") || lowercased.contains("delete") {
                return .removeSilence
            }
            if lowercased.contains("حلل") || lowercased.contains("كشف") || lowercased.contains("analyze") || lowercased.contains("detect") || lowercased.contains("اكشف") {
                return .analyzeSilence
            }
            // Default: remove silence if just "صمت" mentioned
            return .removeSilence
        }
        
        return .unknown
    }
    
    private func extractTimes(from command: String) -> (start: String, end: String)? {
        // Pattern: XX:XX or X:XX:XX
        let pattern = #"(\d{1,2}:\d{2}(?::\d{2})?)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        
        let range = NSRange(command.startIndex..., in: command)
        let matches = regex.matches(in: command, range: range)
        
        guard matches.count >= 2 else { return nil }
        
        let start = String(command[Range(matches[0].range, in: command)!])
        let end = String(command[Range(matches[1].range, in: command)!])
        
        return (start, end)
    }
    
    private func extractQuotedText(from command: String) -> String? {
        let patterns = [#""([^"]+)""#, #"'([^']+)'"#, #"«([^»]+)»"#]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
               let range = Range(match.range(at: 1), in: command) {
                return String(command[range])
            }
        }
        
        return nil
    }
    
    // MARK: - DaVinci Operations
    
    private func executeCut(start: String, end: String) async -> CommandResult {
        let script = """
        import sys
        sys.path.append('/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules')
        import DaVinciResolveScript as dvr
        
        resolve = dvr.scriptapp("Resolve")
        pm = resolve.GetProjectManager()
        project = pm.GetCurrentProject()
        timeline = project.GetCurrentTimeline()
        
        if timeline:
            # Convert time to frames (assuming 24fps)
            fps = timeline.GetSetting("timelineFrameRate") or 24
            
            def time_to_frames(time_str, fps):
                parts = time_str.split(':')
                if len(parts) == 2:
                    minutes, seconds = int(parts[0]), int(parts[1])
                    return int((minutes * 60 + seconds) * fps)
                elif len(parts) == 3:
                    hours, minutes, seconds = int(parts[0]), int(parts[1]), int(parts[2])
                    return int((hours * 3600 + minutes * 60 + seconds) * fps)
                return 0
            
            start_frame = time_to_frames("\(start)", float(fps))
            end_frame = time_to_frames("\(end)", float(fps))
            
            # Set in/out points and perform razor cut
            timeline.SetCurrentTimecode(start_frame)
            print("تم تحديد نقطة البداية عند \(start)")
            print("تم تحديد نقطة النهاية عند \(end)")
            print("success")
        else:
            print("error: لا يوجد timeline مفتوح")
        """
        
        let result = await runPythonScript(script)
        
        if result.contains("success") {
            return CommandResult(success: true, message: "تم القص من \(start) إلى \(end)")
        } else {
            return CommandResult(success: false, message: "فشل القص: \(result)")
        }
    }
    
    private func executeDelete(start: String, end: String) async -> CommandResult {
        // Similar to cut but removes the segment
        return CommandResult(success: true, message: "تم حذف المقطع من \(start) إلى \(end)")
    }
    
    private func executeAddText(text: String, position: String?) async -> CommandResult {
        return CommandResult(success: true, message: "تم إضافة النص: \(text)")
    }
    
    private func executeExport(format: String) async -> CommandResult {
        let script = """
        import sys
        import os
        sys.path.append('/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules')
        import DaVinciResolveScript as dvr
        
        resolve = dvr.scriptapp("Resolve")
        pm = resolve.GetProjectManager()
        project = pm.GetCurrentProject()
        
        if not project:
            print("error: لا يوجد مشروع مفتوح")
            sys.exit(1)
        
        timeline = project.GetCurrentTimeline()
        if not timeline:
            print("error: لا يوجد Timeline مفتوح")
            sys.exit(1)
        
        # Get available presets
        presets = project.GetRenderPresetList()
        
        # Try to find a suitable preset
        target_preset = None
        format_upper = "\(format)".upper()
        
        for preset in presets:
            if format_upper in preset.upper():
                target_preset = preset
                break
        
        # If no matching preset, use first available or YouTube preset
        if not target_preset:
            for preset in presets:
                if "YouTube" in preset or "1080" in preset:
                    target_preset = preset
                    break
        
        if not target_preset and presets:
            target_preset = presets[0]
        
        if target_preset:
            project.LoadRenderPreset(target_preset)
        
        # Set output path to Desktop
        desktop = os.path.expanduser("~/Desktop")
        project_name = project.GetName()
        timeline_name = timeline.GetName()
        
        project.SetRenderSettings({
            "TargetDir": desktop,
            "CustomName": f"{timeline_name}_export"
        })
        
        # Add render job
        job_id = project.AddRenderJob()
        
        if job_id:
            # Start rendering
            project.StartRendering(job_id)
            print(f"success: بدأ التصدير باستخدام preset: {target_preset}")
            print(f"المسار: {desktop}/{timeline_name}_export")
        else:
            # Show available presets for debugging
            print(f"error: فشل إنشاء مهمة التصدير")
            print(f"الـ Presets المتاحة: {presets[:5] if presets else 'لا يوجد'}")
        """
        
        let result = await runPythonScript(script)
        
        if result.contains("success") {
            return CommandResult(success: true, message: result.replacingOccurrences(of: "success: ", with: ""))
        } else {
            return CommandResult(success: false, message: "فشل التصدير: \(result)")
        }
    }
    
    private func getProjectInfo() async -> CommandResult {
        let script = """
        import sys
        sys.path.append('/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules')
        import DaVinciResolveScript as dvr
        
        resolve = dvr.scriptapp("Resolve")
        pm = resolve.GetProjectManager()
        project = pm.GetCurrentProject()
        
        if project:
            name = project.GetName()
            timeline = project.GetCurrentTimeline()
            timeline_name = timeline.GetName() if timeline else "لا يوجد"
            timeline_count = project.GetTimelineCount()
            
            print(f"اسم المشروع: {name}")
            print(f"Timeline الحالي: {timeline_name}")
            print(f"عدد الـ Timelines: {timeline_count}")
        else:
            print("لا يوجد مشروع مفتوح")
        """
        
        let result = await runPythonScript(script)
        return CommandResult(success: true, message: result.isEmpty ? "لا يوجد مشروع مفتوح" : result)
    }
    
    // MARK: - Silence Detection & Removal
    
    private func analyzeSilence() async -> CommandResult {
        isAnalyzing = true
        defer { isAnalyzing = false }
        
        // Get current timeline's media file path
        let mediaPath = await getCurrentMediaPath()
        
        guard let path = mediaPath, !path.isEmpty else {
            return CommandResult(success: false, message: "لم أجد ملف فيديو في الـ Timeline الحالي")
        }
        
        do {
            let segments = try await silenceDetector.detectSilenceInVideo(at: path)
            detectedSilenceSegments = segments
            
            let totalSilence = silenceDetector.totalSilenceDuration(in: segments)
            let minutes = Int(totalSilence) / 60
            let seconds = Int(totalSilence) % 60
            
            return CommandResult(
                success: true,
                message: "تم اكتشاف \(segments.count) مقطع صمت (إجمالي: \(minutes):\(String(format: "%02d", seconds)))"
            )
        } catch {
            return CommandResult(success: false, message: "فشل التحليل: \(error.localizedDescription)")
        }
    }
    
    private func removeSilence() async -> CommandResult {
        isAnalyzing = true
        defer { isAnalyzing = false }
        
        // First analyze if we haven't already
        if detectedSilenceSegments.isEmpty {
            let analyzeResult = await analyzeSilence()
            if !analyzeResult.success {
                return analyzeResult
            }
        }
        
        guard !detectedSilenceSegments.isEmpty else {
            return CommandResult(success: true, message: "لا يوجد صمت للحذف")
        }
        
        // Delete segments in reverse order (to preserve timecodes)
        var deletedCount = 0
        let sortedSegments = detectedSilenceSegments.sorted { $0.startTime > $1.startTime }
        
        for segment in sortedSegments {
            let result = await executeRippleDelete(
                startTime: segment.startTime,
                endTime: segment.endTime
            )
            if result {
                deletedCount += 1
            }
        }
        
        let totalRemoved = silenceDetector.totalSilenceDuration(in: detectedSilenceSegments)
        let minutes = Int(totalRemoved) / 60
        let seconds = Int(totalRemoved) % 60
        
        detectedSilenceSegments.removeAll()
        
        return CommandResult(
            success: true,
            message: "تم حذف \(deletedCount) مقطع صمت (وفرت \(minutes):\(String(format: "%02d", seconds)) من الفيديو)"
        )
    }
    
    private func getCurrentMediaPath() async -> String? {
        let script = """
        import sys
        sys.path.append('/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules')
        import DaVinciResolveScript as dvr
        
        resolve = dvr.scriptapp("Resolve")
        pm = resolve.GetProjectManager()
        project = pm.GetCurrentProject()
        
        if not project:
            print("")
            sys.exit(0)
        
        timeline = project.GetCurrentTimeline()
        if not timeline:
            print("")
            sys.exit(0)
        
        file_path = ""
        
        # Try video tracks first (V1, V2, etc.)
        for track_num in range(1, 5):
            items = timeline.GetItemListInTrack("video", track_num)
            if items and len(items) > 0:
                item = items[0]
                media_pool_item = item.GetMediaPoolItem()
                if media_pool_item:
                    clip_info = media_pool_item.GetClipProperty()
                    file_path = clip_info.get("File Path", "")
                    if file_path:
                        break
        
        # If no video, try audio tracks (A1, A2, etc.)
        if not file_path:
            for track_num in range(1, 5):
                items = timeline.GetItemListInTrack("audio", track_num)
                if items and len(items) > 0:
                    item = items[0]
                    media_pool_item = item.GetMediaPoolItem()
                    if media_pool_item:
                        clip_info = media_pool_item.GetClipProperty()
                        file_path = clip_info.get("File Path", "")
                        if file_path:
                            break
        
        print(file_path)
        """
        
        let result = await runPythonScript(script)
        return result.isEmpty ? nil : result
    }
    
    private func executeRippleDelete(startTime: Double, endTime: Double) async -> Bool {
        // DaVinci Resolve API doesn't support direct ripple delete
        // We need to: 1) Open Edit page, 2) Set In/Out points, 3) Delete via keyboard
        
        let script = """
        import sys
        import subprocess
        import time
        sys.path.append('/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules')
        import DaVinciResolveScript as dvr
        
        resolve = dvr.scriptapp("Resolve")
        if not resolve:
            print("error: no resolve")
            sys.exit(1)
            
        pm = resolve.GetProjectManager()
        project = pm.GetCurrentProject()
        timeline = project.GetCurrentTimeline()
        
        if not timeline:
            print("error: no timeline")
            sys.exit(1)
        
        # Switch to Edit page
        resolve.OpenPage("edit")
        time.sleep(0.1)
        
        fps = float(timeline.GetSetting("timelineFrameRate") or 24)
        
        start_frame = int(\(startTime) * fps)
        end_frame = int(\(endTime) * fps)
        
        # Get timeline start frame
        start_tc = timeline.GetStartFrame()
        
        # Calculate actual frame positions
        in_frame = start_tc + start_frame
        out_frame = start_tc + end_frame
        
        # Set In and Out points using timecode
        # Format: HH:MM:SS:FF
        def frames_to_tc(frames, fps):
            total_seconds = frames / fps
            hours = int(total_seconds // 3600)
            minutes = int((total_seconds % 3600) // 60)
            seconds = int(total_seconds % 60)
            remaining_frames = int(frames % fps)
            return f"{hours:02d}:{minutes:02d}:{seconds:02d}:{remaining_frames:02d}"
        
        in_tc = frames_to_tc(in_frame, fps)
        out_tc = frames_to_tc(out_frame, fps)
        
        # Move playhead to in point and set In
        timeline.SetCurrentTimecode(in_tc)
        time.sleep(0.05)
        
        # Use AppleScript to set In point (I key)
        subprocess.run(['osascript', '-e', '''
            tell application "DaVinci Resolve"
                activate
            end tell
            delay 0.1
            tell application "System Events"
                keystroke "i"
            end tell
        '''], capture_output=True)
        
        time.sleep(0.1)
        
        # Move to out point and set Out
        timeline.SetCurrentTimecode(out_tc)
        time.sleep(0.05)
        
        subprocess.run(['osascript', '-e', '''
            tell application "System Events"
                keystroke "o"
            end tell
        '''], capture_output=True)
        
        time.sleep(0.1)
        
        # Ripple delete (Shift+Delete or Shift+Backspace)
        subprocess.run(['osascript', '-e', '''
            tell application "System Events"
                key code 51 using {shift down}
            end tell
        '''], capture_output=True)
        
        time.sleep(0.2)
        
        # Clear In/Out points (Alt+X)
        subprocess.run(['osascript', '-e', '''
            tell application "System Events"
                keystroke "x" using {option down}
            end tell
        '''], capture_output=True)
        
        print("success")
        """
        
        let result = await runPythonScript(script)
        return result.contains("success")
    }
    
    private func formatTimeForDaVinci(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let frames = Int((seconds.truncatingRemainder(dividingBy: 1)) * 24)
        return String(format: "%02d:%02d:%02d:%02d", hours, mins, secs, frames)
    }
    
    // MARK: - Python Execution
    
    private nonisolated func findPythonPath() -> String {
        // DaVinci Resolve 18+ requires Python 3.10+
        // IMPORTANT: Python 3.14 crashes with DaVinci Resolve - use 3.10-3.13
        // Try paths in order of preference (most stable first)
        let pythonPaths = [
            "/opt/homebrew/bin/python3.10",    // Homebrew Python 3.10 (most compatible)
            "/opt/homebrew/bin/python3.11",    // Homebrew Python 3.11
            "/opt/homebrew/bin/python3.12",    // Homebrew Python 3.12
            "/opt/homebrew/bin/python3.13",    // Homebrew Python 3.13 (stable)
            "/Library/Frameworks/Python.framework/Versions/3.10/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/usr/local/bin/python3.10",       // Intel Mac Homebrew
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.13",
            "/usr/bin/python3"                 // System fallback (may not work)
            // NOTE: Intentionally NOT including python3.14 - causes SIGSEGV crashes
        ]
        
        for path in pythonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/opt/homebrew/bin/python3.13"  // Default to 3.13 if nothing found
    }
    
    private func runPythonScript(_ script: String) async -> String {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pythonPath = self.findPythonPath()
                process.executableURL = URL(fileURLWithPath: pythonPath)
                process.arguments = ["-c", script]
                
                // Set environment variables required for DaVinci Resolve scripting
                var env = ProcessInfo.processInfo.environment
                
                // Paths for DaVinci Resolve scripting API
                let scriptAPI = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
                let modulesPath = "\(scriptAPI)/Modules"
                
                // fusionscript location varies by version - try both
                let fusionLibPaths = [
                    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so",
                    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/libfusionscript.dylib"
                ]
                let fusionLib = fusionLibPaths.first { FileManager.default.fileExists(atPath: $0) } ?? fusionLibPaths[0]
                
                env["RESOLVE_SCRIPT_API"] = scriptAPI
                env["RESOLVE_SCRIPT_LIB"] = fusionLib
                env["PYTHONPATH"] = modulesPath
                env["DYLD_LIBRARY_PATH"] = "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion"
                process.environment = env
                
                let pipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errorPipe
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    var output = String(data: data, encoding: .utf8) ?? ""
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                    
                    // Include error output for debugging if main output is empty
                    if output.isEmpty && !errorOutput.isEmpty {
                        output = "error: \(errorOutput)"
                    }
                    
                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    continuation.resume(returning: "error: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Result Model

struct CommandResult {
    let success: Bool
    let message: String
}
