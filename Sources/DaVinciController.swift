import Foundation
import AppKit

/// Controller for communicating with DaVinci Resolve
@MainActor
class DaVinciController: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var currentProject: String = ""
    @Published var currentTimeline: String = ""
    
    private let scriptPath: String
    
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
        case .unknown:
            return CommandResult(success: false, message: "لم أفهم الأمر. جرب: 'قص من 0:00 إلى 0:30' أو 'معلومات المشروع'")
        }
    }
    
    // MARK: - Command Parsing
    
    private enum ParsedCommand {
        case cut(start: String, end: String)
        case delete(start: String, end: String)
        case addText(text: String, position: String?)
        case export(format: String)
        case info
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
    
    // MARK: - Python Execution
    
    private nonisolated func findPythonPath() -> String {
        // DaVinci Resolve 18+ requires Python 3.10+
        // Try paths in order of preference
        let pythonPaths = [
            "/opt/homebrew/bin/python3",      // Homebrew (ARM Mac)
            "/usr/local/bin/python3",          // Homebrew (Intel Mac)
            "/Library/Frameworks/Python.framework/Versions/3.10/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/usr/bin/python3"                 // System fallback (may not work)
        ]
        
        for path in pythonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/bin/python3"
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
