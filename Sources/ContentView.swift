import SwiftUI
import UniformTypeIdentifiers

// MARK: - Custom UTTypes

extension UTType {
    static var fcpxml: UTType {
        UTType(filenameExtension: "fcpxml", conformingTo: .xml) ?? .xml
    }
    
    static var fcpxmld: UTType {
        UTType(filenameExtension: "fcpxmld", conformingTo: .package) ?? .package
    }
}

enum EditorMode: String, CaseIterable {
    case davinci = "DaVinci Resolve"
    case finalcut = "Final Cut Pro"
}

struct ContentView: View {
    @State private var command: String = ""
    @State private var output: [OutputMessage] = []
    @State private var isProcessing: Bool = false
    @StateObject private var davinciController = DaVinciController()
    @StateObject private var fcpxmlController = FCPXMLController()
    @FocusState private var isTextFieldFocused: Bool
    @State private var editorMode: EditorMode = .finalcut
    @State private var showingFileImporter = false
    @State private var selectedFCPXMLURL: URL?
    
    private var connectionCheckTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Output Area
            outputView
            
            Divider()
            
            // Command Input
            commandInputView
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            checkDaVinciConnection()
            // Activate app and focus text field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.activate(ignoringOtherApps: true)
                isTextFieldFocused = true
            }
        }
        .onReceive(connectionCheckTimer) { _ in
            if editorMode == .davinci {
                Task {
                    await davinciController.checkConnection()
                }
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.fcpxml, .fcpxmld],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    selectedFCPXMLURL = url
                    processFCPXML(url: url)
                }
            case .failure(let error):
                addOutput("خطأ في فتح الملف: \(error.localizedDescription)", type: .error)
            }
        }
    }
    
    // MARK: - FCPXML Processing
    private func processFCPXML(url: URL) {
        addOutput("جاري معالجة: \(url.lastPathComponent)", type: .system)
        
        Task {
            // Handle .fcpxmld bundles (XML is inside as Info.fcpxml)
            let xmlURL: URL
            if url.pathExtension == "fcpxmld" {
                xmlURL = url.appendingPathComponent("Info.fcpxml")
            } else {
                xmlURL = url
            }
            
            // Create output URL
            let outputURL = xmlURL.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_no_silence")
                .appendingPathExtension("fcpxml")
            
            let success = await fcpxmlController.processAndRemoveSilence(
                fcpxmlURL: xmlURL,
                outputURL: outputURL
            )
            
            await MainActor.run {
                if success {
                    addOutput(fcpxmlController.statusMessage, type: .assistant)
                    addOutput("استورد الملف المعدل في Final Cut Pro:\nFile → Import → XML...", type: .system)
                } else {
                    addOutput(fcpxmlController.statusMessage, type: .error)
                }
            }
        }
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack {
            Image(systemName: "film.stack")
                .font(.title2)
                .foregroundColor(.accentColor)
            
            Text("المونتير الذكي")
                .font(.title2)
                .fontWeight(.semibold)
            
            Spacer()
            
            // Editor Mode Picker
            Picker("", selection: $editorMode) {
                ForEach(EditorMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            
            // Quick Actions based on mode
            if editorMode == .finalcut {
                Button(action: { showingFileImporter = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.badge.plus")
                        Text("استيراد FCPXML")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
            } else if davinciController.isConnected {
                Button(action: analyzeCurrentVideo) {
                    HStack(spacing: 4) {
                        if davinciController.isAnalyzing {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "waveform.badge.magnifyingglass")
                        }
                        Text("كشف الصمت")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(davinciController.isAnalyzing)
            }
            
            // Connection Status (only for DaVinci mode)
            if editorMode == .davinci {
                HStack(spacing: 6) {
                    Circle()
                        .fill(davinciController.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(davinciController.isConnected ? "DaVinci متصل" : "غير متصل")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                    Text("Final Cut Pro")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
            }
        }
        .padding()
    }
    
    // MARK: - Output View
    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Silence segments preview (if any)
                    if !davinciController.detectedSilenceSegments.isEmpty {
                        silenceSegmentsView
                    }
                    
                    ForEach(output) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: output.count) { _, _ in
                if let lastMessage = output.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Silence Segments View
    private var silenceSegmentsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform.slash")
                    .foregroundColor(.orange)
                Text("مقاطع الصمت المكتشفة (\(davinciController.detectedSilenceSegments.count))")
                    .font(.headline)
                
                Spacer()
                
                Button(action: removeSilenceSegments) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("حذف الكل")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isProcessing)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(davinciController.detectedSilenceSegments) { segment in
                        SilenceSegmentCard(segment: segment)
                    }
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - Command Input
    private var commandInputView: some View {
        HStack(spacing: 12) {
            TextField("اكتب أمر... (مثال: قص من 0:00 إلى 0:30)", text: $command)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(12)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(10)
                .focused($isTextFieldFocused)
                .onSubmit {
                    executeCommand()
                }
                .disabled(isProcessing || !davinciController.isConnected)
            
            Button(action: executeCommand) {
                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.body)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(command.isEmpty || isProcessing || !davinciController.isConnected)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
    }
    
    // MARK: - Actions
    private func checkDaVinciConnection() {
        Task {
            await davinciController.checkConnection()
            if davinciController.isConnected {
                addOutput("تم الاتصال بـ DaVinci Resolve بنجاح", type: .system)
            } else {
                addOutput("لم يتم العثور على DaVinci Resolve - تأكد من تشغيله", type: .error)
            }
        }
    }
    
    private func executeCommand() {
        guard !command.isEmpty, davinciController.isConnected else { return }
        
        let userCommand = command
        addOutput(userCommand, type: .user)
        command = ""
        isProcessing = true
        
        Task {
            let result = await davinciController.executeCommand(userCommand)
            addOutput(result.message, type: result.success ? .assistant : .error)
            isProcessing = false
            // Re-focus text field after command
            isTextFieldFocused = true
        }
    }
    
    private func addOutput(_ text: String, type: MessageType) {
        let message = OutputMessage(text: text, type: type)
        output.append(message)
    }
    
    private func analyzeCurrentVideo() {
        Task {
            addOutput("جاري تحليل الفيديو لكشف الصمت...", type: .system)
            let result = await davinciController.executeCommand("حلل الصمت")
            addOutput(result.message, type: result.success ? .assistant : .error)
        }
    }
    
    private func removeSilenceSegments() {
        Task {
            isProcessing = true
            addOutput("جاري حذف مقاطع الصمت...", type: .system)
            let result = await davinciController.executeCommand("احذف الصمت")
            addOutput(result.message, type: result.success ? .assistant : .error)
            isProcessing = false
        }
    }
}

// MARK: - Models

struct OutputMessage: Identifiable {
    let id = UUID()
    let text: String
    let type: MessageType
    let timestamp = Date()
}

enum MessageType {
    case user
    case assistant
    case system
    case error
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: OutputMessage
    
    var body: some View {
        HStack {
            if message.type == .user {
                Spacer()
            }
            
            VStack(alignment: message.type == .user ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(textColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(backgroundColor)
                    .cornerRadius(16)
                
                Text(timeString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if message.type != .user {
                Spacer()
            }
        }
    }
    
    private var backgroundColor: Color {
        switch message.type {
        case .user:
            return .accentColor
        case .assistant:
            return Color(.controlBackgroundColor)
        case .system:
            return Color.blue.opacity(0.1)
        case .error:
            return Color.red.opacity(0.1)
        }
    }
    
    private var textColor: Color {
        switch message.type {
        case .user:
            return .white
        case .assistant:
            return .primary
        case .system:
            return .blue
        case .error:
            return .red
        }
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: message.timestamp)
    }
}

// MARK: - Silence Segment Card

struct SilenceSegmentCard: View {
    let segment: SilenceDetector.SilenceSegment
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "waveform.slash")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text(String(format: "%.1f ث", segment.duration))
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            
            Text("\(segment.startTimecode) → \(segment.endTimecode)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
}
