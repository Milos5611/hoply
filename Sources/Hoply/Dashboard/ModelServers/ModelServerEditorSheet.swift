import AgentKit
import SwiftUI

struct ModelServerEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var editor: ModelServerEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(editor.isNew ? "Add model server" : "Edit \(editor.server.displayName)")
                    .font(.system(size: 17, weight: .bold))
                Text("Ollama, LM Studio, llama.cpp, vLLM, SGLang, TGI or any OpenAI-compatible server, on this Mac or remote.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        serverSection
                        signInSection
                        advancedSection
                    }
                    .padding(.trailing, 4)
                }
                .frame(width: 500)
                ModelServerTestResult(editor: editor)
                    .frame(width: 344)
            }
            .frame(height: 520)
            Divider()
            HStack(spacing: 10) {
                if let error = editor.saveError {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { model.modelServers.editor = nil }
                    .keyboardShortcut(.cancelAction)
                Button(editor.isNew ? "Add server" : "Save") { model.saveModelServer(editor) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editor.canSave)
            }
        }
        .font(.system(size: 12.5))
        .padding(20)
        .frame(width: 900)
    }

    // MARK: - Server

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionTitle("Server")
            EditorRow("Name") {
                TextField(editor.server.host.isEmpty ? "Ollama on my Mac" : editor.server.host, text: $editor.name)
                    .textFieldStyle(.roundedBorder)
            }
            EditorRow("URL") {
                TextField("http://localhost:11434", text: $editor.url)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            ForEach(editor.urlNotes) { note in
                EditorNote(note: note)
            }
            EditorRow("Engine") {
                Picker("Engine", selection: $editor.engine) {
                    Text("Auto-detect").tag(ModelEngine?.none)
                    Divider()
                    ForEach(ModelEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(ModelEngine?.some(engine))
                    }
                }
                .labelsHidden()
                .fixedSize()
                if editor.engine == nil, !editor.isTestStale, let detected = editor.probe?.engine {
                    Label("Detected \(detected.displayName)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 0)
            }
            EditorNote(text: "The address the server listens on, without /v1. Auto-detect asks for every API Hoply knows and keeps what answers; choose an engine only to skip that.")
        }
    }

    // MARK: - Sign-in

    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionTitle("Sign-in")
            EditorRow("Method") {
                Picker("Sign-in", selection: $editor.signIn) {
                    ForEach(ModelServerEditor.SignIn.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
            }
            switch editor.signIn {
            case .none:
                EmptyView()
            case .bearer:
                secret("API key", $editor.token, stored: editor.stored.token, prompt: "sk-…")
                EditorNote(text: "Sent as Authorization: Bearer <key>, the way vLLM --api-key, llama-server --api-key, LiteLLM and most proxies expect it.")
            case .basic:
                EditorRow("User name") {
                    TextField("user", text: $editor.username)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                secret("Password", $editor.password, stored: editor.stored.password, prompt: "Password")
                EditorNote(text: "HTTP Basic, as a reverse proxy (nginx, Caddy, Traefik) in front of the server asks for it.")
            case .cloudflareAccess:
                EditorRow("Client ID") {
                    TextField("0123456789abcdef.access", text: $editor.clientID)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                secret("Client secret", $editor.clientSecret, stored: editor.stored.clientSecret, prompt: "Service token secret")
                secret("API key", $editor.token, stored: editor.stored.token, prompt: "Optional: only if the server behind Access wants its own key")
                EditorNote(text: "A service token from Cloudflare Zero Trust → Access → Service Auth. The application needs a policy with the Service Auth action that includes this token.")
            }
            headers
            EditorNote(text: "Keys, passwords and header values are stored in your login Keychain, never in Hoply's settings. An empty field keeps what is saved.")
        }
    }

    private func secret(_ label: String, _ text: Binding<String>, stored: Bool, prompt: String) -> some View {
        EditorRow(label) {
            SecureField(stored ? "Saved in Keychain · type to replace" : prompt, text: text)
                .textFieldStyle(.roundedBorder)
            if stored, text.wrappedValue.isEmpty {
                KeychainMark()
            }
        }
    }

    private var headers: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach($editor.headers) { $header in
                EditorRow(header.id == editor.headers.first?.id ? "Headers" : "") {
                    TextField("X-Header-Name", text: $header.name)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: 170)
                    SecureField(editor.isStored(header: header.name) ? "Saved in Keychain · type to replace" : "Value",
                                text: $header.value)
                        .textFieldStyle(.roundedBorder)
                    if editor.isStored(header: header.name), header.value.isEmpty {
                        KeychainMark()
                    }
                    Button { editor.headers.removeAll { $0.id == header.id } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this header")
                }
            }
            ForEach(editor.headerNotes) { note in
                EditorNote(note: note)
            }
            EditorRow(editor.headers.isEmpty ? "Headers" : "") {
                Button("Add header") { editor.headers.append(ModelServerEditor.Header()) }
                    .buttonStyle(.bordered)
                Text("Sent with every request, on top of the method above")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { editor.showsAdvanced.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: editor.showsAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                    SectionTitle("Advanced")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if editor.showsAdvanced {
                EditorRow("Metrics") {
                    TextField("/metrics", text: $editor.metricsPath)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                EditorNote(text: "Where the Prometheus metrics are, when not at /metrics: a path, or a full URL if they are served on another port or host. Sign-in details are only sent to the server's own host.")
                EditorRow("Alerts") {
                    Toggle("Notify when this server is offline for 2 minutes", isOn: $editor.offlineAlerts)
                    Spacer(minLength: 0)
                }
                EditorRow("Polling") {
                    Toggle("Watch this server", isOn: $editor.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct KeychainMark: View {
    var body: some View {
        Image(systemName: "key.fill")
            .font(.system(size: 11))
            .foregroundStyle(.green)
            .help("Saved in Keychain")
            .accessibilityLabel("Saved in Keychain")
    }
}

private struct EditorRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 92, alignment: .leading)
            content
        }
    }
}

private struct EditorNote: View {
    let text: String
    var isWarning = false

    init(text: String) {
        self.text = text
    }

    init(note: ModelServerEditor.Note) {
        text = note.text
        isWarning = note.isWarning
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if isWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
            }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(isWarning ? Color.orange : Color.secondary)
        .padding(.leading, 100)
    }
}

// MARK: - Test result

struct ModelServerTestResult: View {
    @Environment(AppModel.self) private var model
    @Bindable var editor: ModelServerEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionTitle("Test")
                Spacer()
                if editor.test == .running {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Test connection") { model.testModelServer(editor) }
                    .disabled(editor.test == .running || !editor.server.isConfigured)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let probe = editor.probe {
                        Group {
                            if let status = probe.status {
                                success(probe, status)
                            } else if let error = probe.error {
                                failure(probe, error)
                            }
                            endpoints(probe)
                        }
                        .opacity(editor.isTestStale ? 0.5 : 1)
                        if editor.isTestStale {
                            Hint("The connection settings changed since this test. Test again to check them.")
                        }
                    } else if editor.test == .running {
                        Text("Asking \(editor.server.host)…")
                            .foregroundStyle(.secondary)
                    } else {
                        Hint("Test connection uses what is typed here, before anything is saved. It shows whether Hoply reaches the server, which engine answers, the models it serves and what each endpoint said.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func success(_ probe: ModelServerProbe, _ status: ModelServerStatus) -> some View {
        let snapshot = status.snapshot
        var facts = [snapshot.version.map { "\(snapshot.engine.displayName) \($0)" } ?? snapshot.engine.displayName]
        facts.append(status.models.count == 1 ? "1 model" : "\(status.models.count) models")
        if let latency = probe.latency { facts.append(Self.milliseconds(latency)) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reachable")
                        .font(.system(size: 13, weight: .semibold))
                    Text(facts.joined(separator: " · "))
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    Text(reports(status))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(probe.hints, id: \.self) { hint in
                Label(hint.text, systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
            if !status.models.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Treat as local")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    ForEach(status.models.prefix(12)) { served in
                        ServedModelRow(served: served, compact: true)
                    }
                    if status.models.count > 12 {
                        Hint("\(status.models.count - 12) more on the Local model page.")
                    }
                    Hint("Treat as local: the model costs $0 and its tokens count as saved vs the API. Never set automatically, because a proxy can list cloud models too.")
                }
            }
        }
    }

    private func reports(_ status: ModelServerStatus) -> String {
        let capabilities = status.capabilities
        var shown: [String] = []
        if capabilities.contains(.generationRate) { shown.append("generation speed") }
        if capabilities.contains(.promptRate) { shown.append("prompt tokens") }
        if capabilities.contains(.kvCache) { shown.append("KV cache") }
        if capabilities.contains(.running) || capabilities.contains(.waiting) { shown.append("requests") }
        if capabilities.contains(.loadedModels) { shown.append("loaded models") }
        if capabilities.contains(.memory) { shown.append("memory") }
        if shown.isEmpty { return "It reports its model list only, so the page shows the models and what they saved vs the API." }
        return "It reports: \(shown.joined(separator: ", ")). The Local model page shows exactly these."
    }

    private func failure(_ probe: ModelServerProbe, _ error: RemoteError) -> some View {
        let blocked = probe.availability == .blocked
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: blocked ? (error.isAuthFailure ? "lock.fill" : "exclamationmark.triangle.fill")
                                          : "xmark.circle.fill")
                    .foregroundStyle(blocked ? Color.orange : Color.red)
                Text(error.errorDescription ?? "The server could not be reached")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let advice = advice(for: error) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(advice.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let label = advice.action {
                        Button(label) { advice.run?() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.leading, 21)
            }
        }
    }

    private struct Advice {
        var text: String
        var action: String?
        var run: (() -> Void)?
    }

    private func advice(for error: RemoteError) -> Advice? {
        let editor = editor
        switch error.kind {
        case .noModelServer:
            guard let engine = editor.engine else {
                return Advice(text: "Something answers there, but none of the model server APIs. Check the port: it may be a web UI rather than the API.")
            }
            return Advice(text: "The engine is set to \(engine.displayName). Auto-detect tries every API Hoply knows.",
                          action: "Use Auto-detect") { editor.engine = nil }
        case .accessRequired where editor.signIn != .cloudflareAccess:
            return Advice(text: "Sign in with an Access service token.", action: "Use Cloudflare Access") {
                editor.signIn = .cloudflareAccess
            }
        case .accessRejected:
            return Advice(text: "Check the client ID and secret, that the token hasn't expired, and that the application's policy has a Service Auth rule including it.")
        case .authRequired(let scheme) where editor.signIn == .none:
            if scheme == "basic" {
                return Advice(text: "The server asks for HTTP Basic.", action: "Use user name and password") {
                    editor.signIn = .basic
                }
            }
            return Advice(text: "The server asks for a key.", action: "Use an API key") { editor.signIn = .bearer }
        case .insecureHTTPBlocked, .httpsRequired:
            return Advice(text: "Plain http is only allowed on this Mac, the local network, .local names and Tailscale.",
                          action: "Switch to https") {
                editor.url = editor.normalizedURL.replacingOccurrences(of: "http://", with: "https://",
                                                                       options: [.caseInsensitive, .anchored])
            }
        case .connectionRefused, .timedOut:
            if editor.server.isLoopback {
                return Advice(text: "Check that the server is running and that the port is the one it listens on.")
            }
            return Advice(text: "Check that it is running and the port is right. A server on another machine must listen on all interfaces, not only localhost (Ollama: OLLAMA_HOST=0.0.0.0, llama.cpp: --host 0.0.0.0, LM Studio: Serve on Local Network), and its firewall must allow the port.")
        case .hostNotFound:
            return Advice(text: "Check the spelling. A Tailscale or VPN name only resolves while that network is connected.")
        default:
            return nil
        }
    }

    private func endpoints(_ probe: ModelServerProbe) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { editor.showsEndpoints.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: editor.showsEndpoints ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                    Text("\(probe.endpoints.count { $0.answered }) of \(probe.endpoints.count) endpoints answered")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if editor.showsEndpoints {
                ForEach(probe.endpoints) { report in
                    HStack(spacing: 8) {
                        Image(systemName: report.answered ? "checkmark" : "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(report.answered ? Color.green : Color.secondary)
                            .frame(width: 10)
                        Text(Self.path(report))
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 104, alignment: .leading)
                        Text(report.error.map(Self.short) ?? "OK")
                            .font(.system(size: 11.5))
                            .foregroundStyle(report.answered ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(report.latency.map(Self.milliseconds) ?? "")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .help(report.url)
                }
            }
        }
    }

    private static func path(_ report: ModelServerRouteReport) -> String {
        guard let url = URL(string: report.url), !url.path.isEmpty else { return report.route.path }
        return url.path
    }

    static func milliseconds(_ seconds: TimeInterval) -> String {
        seconds >= 1 ? String(format: "%.1f s", seconds) : "\(max(Format.whole(seconds * 1_000), 1)) ms"
    }

    static func short(_ error: RemoteError) -> String {
        switch error.kind {
        case .invalidURL: return "Not a valid address"
        case .missingToken, .missingSecret: return "No sign-in details saved"
        case .invalidToken, .invalidHeader: return "Sign-in details can't be sent"
        case .tokenRejected(let status, _): return "Key rejected (HTTP \(status))"
        case .credentialsRejected(let status): return "Password rejected (HTTP \(status))"
        case .authRequired: return "Needs sign-in (HTTP 401)"
        case .accessRejected: return "Access refused the token"
        case .accessRequired: return "Behind Access"
        case .htmlPage: return "A web page, not an API"
        case .redirected(let status, _): return "Redirect (HTTP \(status))"
        case .httpsRequired: return "Wants https"
        case .http(let status): return status == 404 ? "Not there (HTTP 404)" : "HTTP \(status)"
        case .noModelServer: return "No model server API"
        case .insecureHTTPBlocked: return "Plain http blocked by macOS"
        case .timedOut: return "No answer in time"
        case .hostNotFound: return "Host not found"
        case .connectionRefused: return "Nothing listening"
        case .tlsFailure: return "No secure connection"
        case .transport: return "Unreachable"
        }
    }
}

struct ServedModelRow: View {
    @Environment(AppModel.self) private var model
    let served: ServedModel
    var compact = false

    var body: some View {
        let patterns = model.settings.localModelPatterns
        let match = PricingTable.localPattern(matching: served.id, in: patterns)
        let viaPattern = match.map { $0.lowercased() != PricingTable.exactLocalPattern(for: served.id) } ?? false
        HStack(spacing: 8) {
            Image(systemName: served.loaded == true ? "cube.fill" : "cube")
                .foregroundStyle(served.loaded == true ? LocalModelStyle.tint : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(served.id)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(pattern: viaPattern ? match : nil))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(served.id)
            Spacer(minLength: 8)
            if !compact {
                Text("Treat as local")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Toggle("Treat \(served.id) as local", isOn: Binding(get: { match != nil },
                                                               set: { model.setTreatedAsLocal(served.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(viaPattern)
                .help(viaPattern
                      ? "Local because its name contains \"\(match ?? "")\", a pattern in Settings → History → Local models"
                      : "A local model costs $0 and is priced at the reference model to show what it saved vs the API")
        }
    }

    private func detail(pattern: String?) -> String {
        var parts: [String] = []
        switch served.loaded {
        case true?: parts.append("loaded")
        case false?: parts.append("not loaded")
        case nil: break
        }
        if let bytes = served.memoryBytes { parts.append(ModelServerText.memory(bytes)) }
        if let context = served.contextLength { parts.append("\(Format.tokens(context)) context") }
        if let detail = served.detail, !detail.isEmpty { parts.append(detail) }
        if let owner = served.ownedBy, !owner.isEmpty { parts.append("by \(owner)") }
        if let pattern { parts.insert("local via \"\(pattern)\"", at: 0) }
        return parts.isEmpty ? "served" : parts.joined(separator: " · ")
    }
}
