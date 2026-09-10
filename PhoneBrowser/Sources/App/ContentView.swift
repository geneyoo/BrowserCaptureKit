import BrowserCaptureKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: PhoneBrowserModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var relayURLText = ""
    @State private var pairingCode = ""

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            addressBar
            ZStack {
                BrowserCaptureWebView(session: model.owner.session)
                if model.showsHUD {
                    BrowserAccessibilityHUDOverlay(snapshot: model.latestSnapshot)
                        .allowsHitTesting(false)
                }
            }
            controls
        }
        .task {
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            model.setScenePhase(phase)
        }
        .sheet(isPresented: Binding(get: { model.credential == nil }, set: { _ in })) {
            pairingSheet
                .interactiveDismissDisabled()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(readinessText, systemImage: readinessSymbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(readinessColor)
            Text(connectionText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.credentialWarning != nil {
                Image(systemName: "key.slash")
                    .foregroundStyle(.orange)
                    .help(model.credentialWarning ?? "")
            }
            Spacer()
            Text("gen \(model.coordinator.controllerGeneration)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var addressBar: some View {
        HStack {
            TextField("Address", text: $model.addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.navigateFromAddressBar() }
            Button("Go") { model.navigateFromAddressBar() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var controls: some View {
        HStack {
            if model.coordinator.humanControl {
                Button("Return control to agent", systemImage: "play.fill") { model.resume() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Take control", systemImage: "hand.raised.fill") { model.takeover() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Toggle("HUD", isOn: $model.showsHUD)
                .toggleStyle(.button)
            Menu {
                if let credential = model.credential {
                    Text("Device \(credential.deviceID)")
                    Text(credential.relayURL.absoluteString)
                }
                Button("Unpair", role: .destructive) { model.unpair() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var pairingSheet: some View {
        NavigationStack {
            Form {
                Section("Relay") {
                    TextField("http://relay-host:8787", text: $relayURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("One-time pairing code") {
                    TextField("123456", text: $pairingCode)
                        .keyboardType(.numberPad)
                }
                if let error = model.pairingError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let startupError = model.startupError {
                    Section { Text(startupError).foregroundStyle(.orange) }
                }
                Section {
                    Button(model.isPairing ? "Pairing…" : "Pair this phone") {
                        Task { await model.pair(relayURLText: relayURLText, code: pairingCode) }
                    }
                    .disabled(model.isPairing || relayURLText.isEmpty || pairingCode.isEmpty)
                }
            }
            .navigationTitle("Pair with relay")
        }
    }

    private var readinessText: String {
        switch model.readiness {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .ready: "Ready"
        case .executing: "Executing"
        case .humanControl: "Human control"
        case .foregroundRequired: "Foreground required"
        case .recovering: "Recovering"
        }
    }

    private var readinessSymbol: String {
        switch model.readiness {
        case .ready: "checkmark.circle.fill"
        case .executing: "bolt.fill"
        case .humanControl: "hand.raised.fill"
        case .recovering, .connecting: "arrow.triangle.2.circlepath"
        case .disconnected, .foregroundRequired: "exclamationmark.circle"
        }
    }

    private var readinessColor: Color {
        switch model.readiness {
        case .ready, .executing: .green
        case .humanControl: .orange
        case .recovering, .connecting: .yellow
        case .disconnected, .foregroundRequired: .red
        }
    }

    private var connectionText: String {
        switch model.connectionState {
        case .connected: "relay connected"
        case .connecting: "relay connecting"
        case .disconnected(let reason): reason.map { "relay offline: \($0)" } ?? "relay offline"
        }
    }
}
