import SwiftUI

struct ContentView: View {
    @State private var command: String = ""
    @State private var output: [OutputMessage] = []
    @State private var isProcessing: Bool = false
    @StateObject private var davinciController = DaVinciController()
    
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
        .background(Color(.windowBackgroundColor))
        .onAppear {
            checkDaVinciConnection()
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
            
            // Connection Status
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
        }
        .padding()
    }
    
    // MARK: - Output View
    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
    
    // MARK: - Command Input
    private var commandInputView: some View {
        HStack(spacing: 12) {
            TextField("اكتب أمر... (مثال: قص من 0:00 إلى 0:30)", text: $command)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(12)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(10)
                .onSubmit {
                    executeCommand()
                }
                .disabled(isProcessing)
            
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
            .disabled(command.isEmpty || isProcessing)
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
        guard !command.isEmpty else { return }
        
        let userCommand = command
        addOutput(userCommand, type: .user)
        command = ""
        isProcessing = true
        
        Task {
            let result = await davinciController.executeCommand(userCommand)
            addOutput(result.message, type: result.success ? .assistant : .error)
            isProcessing = false
        }
    }
    
    private func addOutput(_ text: String, type: MessageType) {
        let message = OutputMessage(text: text, type: type)
        output.append(message)
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

// Preview requires Xcode, removed for SPM build
