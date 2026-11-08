import SwiftUI
import AppKit

final class SettingsModel: ObservableObject {
    @Published var autoRestore: Bool { didSet { persist() } }
    @Published var autoRecord: Bool { didSet { persist() } }
    @Published var restoreDelay: Double { didSet { persist() } }
    @Published var ignored: String { didSet { persist() } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard !loading else { return }
            if let error = LoginItem.set(launchAtLogin) {
                note = error
                loading = true
                launchAtLogin = LoginItem.isEnabled
                loading = false
            }
            loginStatus = LoginItem.statusDescription
        }
    }

    @Published var profiles: [Profile] = []
    @Published var trusted: Bool = AX.isTrusted
    @Published var loginStatus: String = LoginItem.statusDescription
    @Published var note: String?

    private var loading = false

    init() {
        let s = LayoutStore.shared.settings
        autoRestore = s.autoRestore
        autoRecord = s.autoRecord
        restoreDelay = s.restoreDelay
        ignored = s.ignoredBundleIDs.joined(separator: ", ")
        launchAtLogin = LoginItem.isEnabled
        reload()
    }

    func reload() {
        let s = LayoutStore.shared.settings
        loading = true
        autoRestore = s.autoRestore
        autoRecord = s.autoRecord
        restoreDelay = s.restoreDelay
        ignored = s.ignoredBundleIDs.joined(separator: ", ")
        launchAtLogin = LoginItem.isEnabled
        loading = false
        profiles = LayoutStore.shared.profiles.values.sorted { $0.updatedAt > $1.updatedAt }
        trusted = AX.isTrusted
        loginStatus = LoginItem.statusDescription
    }

    private func persist() {
        guard !loading else { return }
        let ids = ignored
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        LayoutStore.shared.mutateSettings {
            $0.autoRestore = autoRestore
            $0.autoRecord = autoRecord
            $0.restoreDelay = restoreDelay
            $0.ignoredBundleIDs = ids
        }
    }

    func delete(_ profile: Profile) {
        LayoutStore.shared.remove(key: profile.id)
        reload()
    }

    func revealStateFile() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.stateURL])
    }

    func openAccessibility() {
        AX.promptIfNeeded()
        AX.openAccessibilitySettings()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Behaviour") {
                Toggle("Restore automatically after the displays come back", isOn: $model.autoRestore)
                Toggle("Keep remembering the current layout in the background", isOn: $model.autoRecord)
                VStack(alignment: .leading) {
                    HStack {
                        Text("Wait after the displays come back")
                        Spacer()
                        Text(String(format: "%.1f s", model.restoreDelay))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $model.restoreDelay, in: 2.0...10.0, step: 0.5)
                    Text("ReSettle also waits until the display setup has stopped changing and the layout has been still for this long, so it never acts while macOS is still rebuilding the desktop. Lower than 2 s has no effect — that floor is a safety margin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Permissions") {
                HStack {
                    Circle()
                        .fill(model.trusted ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.trusted ? "Accessibility access granted" : "Accessibility access required")
                    Spacer()
                    Button(model.trusted ? "Open Settings" : "Grant Access…") {
                        model.openAccessibility()
                    }
                }
                if !model.trusted {
                    Text("Without this permission ReSettle can only watch the display setup — it cannot move windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                if model.loginStatus != "On" && model.loginStatus != "Off" {
                    Text(model.loginStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = model.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Remembered setups") {
                if model.profiles.isEmpty {
                    Text("Nothing remembered yet. Use any display arrangement for a moment and it will show up here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.profiles, id: \.id) { profile in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).fontWeight(.medium)
                            Text(profile.displayNames.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(profile.windowCount) windows · updated \(Self.dateFormatter.string(from: profile.updatedAt))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            model.delete(profile)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this setup")
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Ignored apps") {
                TextField("Bundle IDs, comma separated", text: $model.ignored)
                Text("Example: com.apple.Safari, com.tinyspeck.slackmacgap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Reveal State File") { model.revealStateFile() }
                Button("Refresh") { model.reload() }
                Spacer()
                Text("Log: ~/Library/Application Support/ReSettle/")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.bar)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 580)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
