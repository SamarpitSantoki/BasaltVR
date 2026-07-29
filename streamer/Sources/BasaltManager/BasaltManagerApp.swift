import SwiftUI
import Charts
import UniformTypeIdentifiers
import BasaltBottleKit
import BasaltCore
import BasaltManagerKit

@main
struct BasaltManagerApp: App {
    @NSApplicationDelegateAdaptor(BasaltApplicationDelegate.self) private var appDelegate
    @StateObject private var model = BasaltAppModel()

    var body: some Scene {
        WindowGroup("BasaltVR") {
            RootView(model: model)
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }
    }
}

private final class BasaltApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct RootView: View {
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        NavigationSplitView {
            List(ManagerSection.allCases, selection: $model.selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("BasaltVR")
            .safeAreaInset(edge: .bottom) {
                sessionBadge
                    .padding(12)
            }
        } detail: {
            Group {
                switch model.selection {
                case .setup: SetupView(model: model)
                case .library: LibraryView(model: model)
                case .bottles: BottlesView(model: model)
                case .stream: StreamDashboardView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button { Task { await model.refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                }
            }
        }
        .alert("BasaltVR", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in
            model.stop()
        }
    }

    private var sessionBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.sessionState.isActive ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(model.sessionState.label)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
    }
}

private struct SetupView: View {
    @ObservedObject var model: BasaltAppModel

    private var readyCount: Int {
        model.setupChecks.filter { $0.status == .ready }.count
    }

    private var requiredReady: Bool {
        model.setupChecks.filter(\.required).allSatisfy { $0.status == .ready }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    eyebrow: "GET READY",
                    title: requiredReady ? "Your Mac is ready" : "Set up BasaltVR",
                    detail: "Finish the required checks, then create a bottle and add a detected game.")

                HStack(spacing: 16) {
                    ProgressView(
                        value: Double(readyCount),
                        total: Double(max(model.setupChecks.count, 1)))
                        .progressViewStyle(.linear)
                    Text("\(readyCount) of \(model.setupChecks.count) ready")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    ForEach(model.setupChecks) { check in
                        SetupCheckRow(check: check) {
                            Task { await model.installDependency(for: check) }
                        }
                        if check.id != model.setupChecks.last?.id { Divider() }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))

                Text("Required checks enable game streaming. Android Platform Tools are only needed for USB cable mode; wireless uses the local Wi-Fi network. Screen Recording is only needed for the desktop preview, and BlackHole is optional when playing without game audio.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle("Setup")
    }
}

private struct SetupCheckRow: View {
    let check: SetupCheck
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(check.title).fontWeight(.semibold)
                    if !check.required {
                        Text("OPTIONAL")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(check.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if check.status != .ready, check.action != nil {
                Button(check.action!, action: action)
            } else if check.status == .ready {
                Text("Ready")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
    }

    private var symbol: String {
        switch check.status {
        case .ready: return "checkmark.circle.fill"
        case .actionNeeded: return "exclamationmark.circle.fill"
        case .unavailable: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch check.status {
        case .ready: return .green
        case .actionNeeded: return .orange
        case .unavailable: return .red
        }
    }
}

private struct LibraryView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var search = ""
    @State private var showTools = false
    @State private var vrOnly = false

    private var steamGames: [SteamGame] {
        model.steamGames.filter {
            (showTools || !$0.isTool)
                && (!vrOnly || $0.isKnownVRGame)
                && (search.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.bottleName.localizedCaseInsensitiveContains(search))
        }
    }

    private var directGames: [DetectedGame] {
        model.games.filter { game in
            let isPresentedAsBSManagerInstance = game.source == .bsmanager
                && model.bsManagerInstances.contains {
                    $0.executable.standardizedFileURL
                        == game.hostExecutable?.standardizedFileURL
                }
            return !isPresentedAsBSManagerInstance
                && (search.isEmpty
                    || game.title.localizedCaseInsensitiveContains(search)
                    || game.bottleName.localizedCaseInsensitiveContains(search))
        }
    }

    private var bsManagerInstances: [BSManagerInstance] {
        model.bsManagerInstances.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.directory.path.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    eyebrow: "PLAY",
                    title: "Game Library",
                    detail: "Steam libraries, BSManager instances, launch profiles, Whisky, and CrossOver are scanned automatically.")

                BSManagerLauncherPanel(model: model)

                HStack {
                    TextField("Search games or bottles", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Toggle("VR only", isOn: $vrOnly)
                    Toggle("Show Steam tools", isOn: $showTools)
                    Spacer()
                    Button("Locate BSManager…") { chooseBSManagerLocation() }
                    Text("\(steamGames.count + bsManagerInstances.count + directGames.count) items")
                        .foregroundStyle(.secondary)
                }

                if steamGames.isEmpty && bsManagerInstances.isEmpty && directGames.isEmpty {
                    ContentUnavailableView {
                        Label("No games detected", systemImage: "gamecontroller")
                    } description: {
                        Text("No Steam games, BSManager instances, or Basalt launch profiles match this filter.")
                    } actions: {
                        Button("Open Bottles") { model.selection = .bottles }
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    if !steamGames.isEmpty {
                        SectionHeader(title: "Steam", count: steamGames.count)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                            ForEach(steamGames) { game in
                                SteamGameCard(game: game, model: model)
                            }
                        }
                    }
                    if !bsManagerInstances.isEmpty {
                        SectionHeader(title: "BSManager", count: bsManagerInstances.count)
                            .padding(.top, steamGames.isEmpty ? 0 : 10)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300), spacing: 16)],
                            spacing: 16
                        ) {
                            ForEach(bsManagerInstances) { instance in
                                BSManagerInstanceCard(instance: instance, model: model)
                            }
                        }
                    }
                    if !directGames.isEmpty {
                        SectionHeader(title: "Profiles & direct installs", count: directGames.count)
                            .padding(.top,
                                     steamGames.isEmpty && bsManagerInstances.isEmpty ? 0 : 10)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                            ForEach(directGames) { game in
                            GameCard(game: game, model: model)
                        }
                    }
                    }
                }
            }
            .padding(32)
        }
        .navigationTitle("Game Library")
    }

    private func chooseBSManagerLocation() {
        let panel = NSOpenPanel()
        panel.title = "Locate BSManager or a Beat Saber Instance"
        panel.message = "Choose an installation parent, BSManager, BSInstances, or an individual instance folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let location = panel.url else { return }
        Task { await model.setBSManagerLocation(location) }
    }
}

private struct BSManagerLauncherPanel: View {
    @ObservedObject var model: BasaltAppModel
    @State private var selectedInstaller: BSManagerInstallerSelection?

    var body: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BSManager").font(.headline)
                    if model.bsManagerInstallations.isEmpty {
                        Text("Install BSManager in a Basalt bottle to download and manage modded Beat Saber versions.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("\(model.bsManagerInstallations.count) launcher\(model.bsManagerInstallations.count == 1 ? "" : "s") available • \(model.bsManagerInstances.count) instance\(model.bsManagerInstances.count == 1 ? "" : "s") found")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.bsManagerInstallations.count == 1,
                   let installation = model.bsManagerInstallations.first {
                    Button {
                        model.launchBSManager(installation)
                    } label: {
                        Label("Open BSManager", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.sessionState.isActive)
                    .fixedSize()
                } else if !model.bsManagerInstallations.isEmpty {
                    Menu {
                        ForEach(model.bsManagerInstallations) { installation in
                            Button(installation.bottleName) {
                                model.launchBSManager(installation)
                            }
                        }
                    } label: {
                        Label("Open BSManager", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.sessionState.isActive)
                    .fixedSize()
                }
                Menu {
                    Button("Choose Windows Installer…") { chooseInstaller() }
                    Button("Open Official Releases") {
                        NSWorkspace.shared.open(URL(
                            string: "https://github.com/Zagrios/bs-manager/releases/latest")!)
                    }
                } label: {
                    Label(
                        model.bsManagerInstallations.isEmpty ? "Install" : "Install or Update",
                        systemImage: "arrow.down.app")
                }
                .disabled(model.sessionState.isActive)
                .fixedSize()
            }
            .padding(.vertical, 5)
        }
        .sheet(item: $selectedInstaller) { selection in
            BSManagerInstallerSheet(installer: selection.url, model: model)
        }
    }

    private func chooseInstaller() {
        guard !model.bottles.isEmpty else {
            model.alertMessage = "Create a Basalt bottle before installing BSManager."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose the BSManager Windows Installer"
        panel.message = "Select BSManager-Setup-*.exe downloaded from the official BSManager release."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedInstaller = BSManagerInstallerSelection(url: url)
    }
}

private struct BSManagerInstallerSelection: Identifiable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
}

private struct BSManagerInstallerSheet: View {
    let installer: URL
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBottle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Install BSManager").font(.title2.bold())
            Text("The Windows installer will run in the selected Basalt bottle. BSManager and the Beat Saber versions it creates will stay isolated in that bottle.")
                .foregroundStyle(.secondary)
            LabeledContent("Installer") {
                Text(installer.lastPathComponent).font(.callout.monospaced())
            }
            Picker("Basalt bottle", selection: $selectedBottle) {
                Text("Select a bottle").tag("")
                ForEach(model.bottles, id: \.name) { bottle in
                    Text(bottle.name).tag(bottle.name)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Run Installer") {
                    guard let bottle = model.bottles.first(where: {
                        $0.name == selectedBottle
                    }) else { return }
                    model.runBSManagerInstaller(installer, in: bottle)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBottle.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 600)
        .onAppear {
            if selectedBottle.isEmpty {
                selectedBottle = model.bsManagerInstallations.first?.bottleName
                    ?? (model.bottles.count == 1 ? model.bottles[0].name : "")
            }
        }
    }
}

private struct BSManagerInstanceCard: View {
    let instance: BSManagerInstance
    @ObservedObject var model: BasaltAppModel
    @State private var presentedSheet: BSManagerCardSheet?

    private var profile: LaunchProfile? { model.profile(for: instance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                Image(systemName: instance.isModded ? "wand.and.stars" : "music.note")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.purple)
                    .frame(width: 52, height: 52)
                    .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Spacer()
                HStack(spacing: 6) {
                    Text("BSMANAGER")
                    if instance.isModded { Text("MODDED") }
                }
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Beat Saber \(instance.name)")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(instance.directory.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                if let profile {
                    Button {
                        Task { await model.launch(profileName: profile.name) }
                    } label: {
                        Label("Play VR", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.sessionState.isActive)
                    Button { presentedSheet = .edit(profile) } label: {
                        Image(systemName: "pencil")
                    }
                    Button { presentedSheet = .settings(profile.name) } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                } else {
                    Button("Create VR Profile") {
                        if let bottleName = instance.bottleName,
                           let bottle = model.bottles.first(where: {
                               $0.name == bottleName
                           }) {
                            Task {
                                await model.createBSManagerProfile(
                                    for: instance, in: bottle)
                            }
                        } else if model.bottles.count == 1,
                                  let bottle = model.bottles.first {
                            Task {
                                await model.createBSManagerProfile(
                                    for: instance, in: bottle)
                            }
                        } else {
                            presentedSheet = .chooseBottle
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([instance.executable])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show instance in Finder")
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .chooseBottle:
                BSManagerBottleSheet(instance: instance, model: model)
            case .edit(let profile):
                ProfileEditorSheet(profile: profile, model: model)
            case .settings(let profileName):
                PerGameSettingsSheet(profileName: profileName, model: model)
            }
        }
    }
}

private enum BSManagerCardSheet: Identifiable {
    case chooseBottle
    case edit(LaunchProfile)
    case settings(String)

    var id: String {
        switch self {
        case .chooseBottle: "choose-bottle"
        case .edit(let profile): "edit-\(profile.name)"
        case .settings(let profileName): "settings-\(profileName)"
        }
    }
}

private struct BSManagerBottleSheet: View {
    let instance: BSManagerInstance
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBottle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create BSManager Profile").font(.title2.bold())
            Text("Choose the isolated Basalt bottle that will run Beat Saber \(instance.name). The BSManager instance stays in place and is not modified.")
                .foregroundStyle(.secondary)

            if model.bottles.isEmpty {
                ContentUnavailableView(
                    "No Basalt bottle",
                    systemImage: "shippingbox",
                    description: Text("Create and prepare a bottle before adding this instance."))
            } else {
                Picker("Basalt bottle", selection: $selectedBottle) {
                    Text("Select a bottle").tag("")
                    ForEach(model.bottles, id: \.name) { bottle in
                        Text(bottle.name).tag(bottle.name)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create Profile") {
                    guard let bottle = model.bottles.first(where: {
                        $0.name == selectedBottle
                    }) else { return }
                    Task {
                        await model.createBSManagerProfile(for: instance, in: bottle)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBottle.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 580)
        .onAppear {
            if selectedBottle.isEmpty {
                selectedBottle = instance.bottleName
                    ?? (model.bottles.count == 1 ? model.bottles[0].name : "")
            }
        }
    }
}

private struct GameCard: View {
    let game: DetectedGame
    @ObservedObject var model: BasaltAppModel
    @State private var presentedSheet: GameCardSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 52, height: 52)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Spacer()
                Text(game.source.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title).font(.title3.weight(.semibold))
                Text("Bottle: \(game.bottleName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(game.executable)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            HStack {
                if let profile = game.profileName {
                    Button {
                        Task { await model.launch(profileName: profile) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.sessionState.isActive)
                    Button {
                        if let profile = model.profiles.first(where: { $0.name == profile }) {
                            presentedSheet = .edit(profile)
                        }
                    } label: { Image(systemName: "pencil") }
                    .help("Edit profile")
                    Button {
                        presentedSheet = .settings(profile)
                    } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Per-game stream settings")
                } else {
                    Button("Create Launch Profile") {
                        Task { await model.createProfile(for: game) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                if game.hostExecutable != nil {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([game.hostExecutable!])
                    } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                }
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .edit(let profile):
                ProfileEditorSheet(profile: profile, model: model)
            case .settings(let profileName):
                PerGameSettingsSheet(profileName: profileName, model: model)
            case .importBottle:
                EmptyView()
            }
        }
    }
}

private struct SteamGameCard: View {
    let game: SteamGame
    @ObservedObject var model: BasaltAppModel
    @State private var presentedSheet: GameCardSheet?

    private var bottle: DiscoveredBottle? {
        model.discoveredBottles.first { $0.id == game.bottleID }
    }

    private var profile: LaunchProfile? { model.profile(for: game) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let artwork = game.artwork,
                       let image = NSImage(contentsOf: artwork) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [.blue.opacity(0.45), .purple.opacity(0.25)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 34)).foregroundStyle(.white.opacity(0.8)))
                    }
                }
                .frame(height: 118)
                .frame(maxWidth: .infinity)
                .clipped()
                HStack {
                    Text(game.bottleOrigin.label.uppercased())
                    if game.isKnownVRGame { Text("VR") }
                }
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(game.name).font(.title3.weight(.semibold)).lineLimit(1)
                Text("\(game.bottleName) • Steam \(game.appID)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    if let size = game.sizeOnDisk {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let played = game.lastPlayed {
                        Text("Played \(played, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption).foregroundStyle(.tertiary)
            }

            HStack {
                if let profile {
                    Button {
                        Task { await model.launch(profileName: profile.name) }
                    } label: { Label("Play VR", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.sessionState.isActive)
                    Button { presentedSheet = .edit(profile) } label: { Image(systemName: "pencil") }
                    Button { presentedSheet = .settings(profile.name) } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                } else if game.bottleOrigin == .managed {
                    Button("Create VR Profile") {
                        Task { await model.createSteamProfile(for: game) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Copy Bottle into Basalt") {
                        if let bottle {
                            presentedSheet = .importBottle(bottle)
                        } else {
                            model.alertMessage = "Basalt could not find the source bottle for this Steam game. Refresh the library and try again."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([game.installDirectory])
                } label: { Image(systemName: "folder") }
                .help("Show game files")
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .importBottle(let bottle):
                ImportBottleSheet(bottle: bottle, model: model)
            case .edit(let profile):
                ProfileEditorSheet(profile: profile, model: model)
            case .settings(let profileName):
                PerGameSettingsSheet(profileName: profileName, model: model)
            }
        }
    }
}

private struct BottlesView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var newName = ""
    @State private var selectedEngine = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    eyebrow: "WINDOWS ENVIRONMENTS",
                    title: "Bottle Manager",
                    detail: "Basalt, Whisky, and CrossOver bottles are shown together. External bottles stay untouched.")

                GroupBox("Create bottle") {
                    HStack {
                        TextField("Name, for example beat-saber", text: $newName)
                        Picker("Engine", selection: $selectedEngine) {
                            Text("Select an engine").tag("")
                            ForEach(model.engines, id: \.id) { engine in
                                Text(engine.id).tag(engine.id)
                            }
                        }
                        .frame(maxWidth: 300)
                        Button("Create") {
                            let name = newName
                            let engine = selectedEngine
                            newName = ""
                            Task { await model.createBottle(name: name, engineID: engine) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.isEmpty || selectedEngine.isEmpty || model.isBusy)
                    }
                    .padding(.top, 6)
                }

                if model.discoveredBottles.isEmpty {
                    ContentUnavailableView(
                        "No Wine bottles found",
                        systemImage: "shippingbox",
                        description: Text("Create a Basalt bottle or install one through Whisky or CrossOver."))
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    let managed = model.discoveredBottles.filter(\.isManaged)
                    let external = model.discoveredBottles.filter { !$0.isManaged }
                    if !managed.isEmpty {
                        SectionHeader(title: "Basalt managed", count: managed.count)
                    VStack(spacing: 0) {
                            ForEach(managed) { bottle in
                            BottleRow(bottle: bottle, model: model)
                                if bottle.id != managed.last?.id { Divider() }
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if !external.isEmpty {
                        SectionHeader(title: "Discovered external bottles", count: external.count)
                            .padding(.top, managed.isEmpty ? 0 : 10)
                        Text("Copying makes an isolated APFS clone for Basalt VR. Whisky and CrossOver originals are never patched.")
                            .font(.footnote).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(external) { bottle in
                                BottleRow(bottle: bottle, model: model)
                                if bottle.id != external.last?.id { Divider() }
                            }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(32)
        }
        .onAppear {
            if selectedEngine.isEmpty {
                selectedEngine = model.engines.first(where: \.supportsBasaltDXMT)?.id ?? ""
            }
        }
        .onChange(of: model.engines) { _, engines in
            if selectedEngine.isEmpty {
                selectedEngine = engines.first(where: \.supportsBasaltDXMT)?.id ?? ""
            }
        }
        .navigationTitle("Bottles")
    }
}

private struct BottleRow: View {
    let bottle: DiscoveredBottle
    @ObservedObject var model: BasaltAppModel
    @State private var showingImport = false

    private var complete: Bool { bottle.isReadyForVR }
    private var hasSteam: Bool {
        model.steamGames.contains { $0.bottleID == bottle.id }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: complete ? "checkmark.seal.fill" : "shippingbox")
                .font(.title2)
                .foregroundStyle(complete ? .green : .secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(bottle.name).fontWeight(.semibold)
                Text(bottle.managed?.engineID ?? bottle.prefix.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(bottle.origin.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            if let managed = bottle.managed {
                StatusPill(text: "DXMT", ready: managed.dxmtInstalled)
                StatusPill(text: "OpenXR", ready: managed.runtimeInstalled)
            }
            Menu {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([bottle.prefix])
                }
                if bottle.isManaged, hasSteam {
                    Button("Launch Steam") { model.launchSteam(in: bottle) }
                }
                if bottle.isManaged {
                    Button("Run Windows Installer…") { chooseInstaller() }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            if bottle.isManaged && !complete {
                Button("Prepare") {
                    Task { await model.prepareBottle(bottle.name) }
                }
                .disabled(model.isBusy)
            } else if !bottle.isManaged {
                Button("Copy into Basalt") { showingImport = true }
                    .disabled(model.isBusy)
            }
        }
        .padding(16)
        .sheet(isPresented: $showingImport) {
            ImportBottleSheet(bottle: bottle, model: model)
        }
    }

    private func chooseInstaller() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows Installer"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe")!, UTType(filenameExtension: "msi")!,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.runInstaller(url, in: bottle)
    }
}

private struct StatusPill: View {
    let text: String
    let ready: Bool

    var body: some View {
        Label(text, systemImage: ready ? "checkmark" : "minus")
            .font(.caption.weight(.medium))
            .foregroundStyle(ready ? .green : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }
}

private struct StreamDashboardView: View {
    @ObservedObject var model: BasaltAppModel

    private var launchableProfiles: [LaunchProfile] {
        model.profiles.filter { profile in
            model.bottles.contains {
                $0.name == profile.bottleName && $0.dxmtInstalled && $0.runtimeInstalled
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    eyebrow: "LIVE SESSION",
                    title: "Stream Dashboard",
                    detail: model.sessionState.label)

                settingsPanel

                HStack(spacing: 14) {
                    MetricCard(title: "Quest FPS", value: latest(\.fps), suffix: "fps", color: .green)
                    MetricCard(title: "Wire rate", value: latest(\.megabits), suffix: "Mbps", color: .blue)
                    MetricCard(title: "Input → display", value: latest(\.latencyMilliseconds), suffix: "ms", color: .orange)
                }

                if !model.metrics.isEmpty {
                    HStack(spacing: 14) {
                        MetricChart(title: "Frame rate", samples: model.metrics, keyPath: \.fps, color: .green)
                        MetricChart(title: "Latency", samples: model.metrics, keyPath: \.latencyMilliseconds, color: .orange)
                    }
                    .frame(height: 190)
                }

                GroupBox("Session log") {
                    ScrollView {
                        Text(model.log.isEmpty ? "Session output will appear here." : model.log)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 140, maxHeight: 260)
                }
            }
            .padding(32)
        }
        .navigationTitle("Stream")
    }

    private var settingsPanel: some View {
        GroupBox("Streaming controls") {
            VStack(spacing: 14) {
                StreamSettingsControls(
                    settings: $model.settings, audioDevices: model.audioDevices)
                .disabled(model.sessionState.isActive)
                HStack {
                    Text(model.settings.connection == .wired
                         ? "ALVR connects through adb over USB."
                         : "ALVR is discovered and streamed to over the local Wi-Fi network; no USB cable or adb is required.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    if model.sessionState.isActive {
                        Button("Stop", role: .destructive) { model.stop() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Menu {
                            ForEach(launchableProfiles, id: \.name) { profile in
                                Button(profile.name) {
                                    Task { await model.launch(profileName: profile.name) }
                                }
                            }
                        } label: {
                            Label("Start Game", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(launchableProfiles.isEmpty)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func latest(_ keyPath: KeyPath<StreamMetricSample, Double?>) -> Double? {
        model.metrics.reversed().compactMap { $0[keyPath: keyPath] }.first
    }
}

private struct SettingsView: View {
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    eyebrow: "PREFERENCES",
                    title: "Settings",
                    detail: "Defaults persist between launches; individual profiles can override them.")

                GroupBox("Default stream") {
                    StreamSettingsControls(
                        settings: $model.settings, audioDevices: model.audioDevices)
                        .padding(.top, 8)
                    HStack {
                        Text("Used by every profile without a custom override.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore Defaults") { model.settings = StreamLaunchSettings() }
                    }
                    .padding(.top, 8)
                }

                GroupBox("Storage") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Basalt data") {
                            Text(model.dataRoot.path).font(.callout.monospaced()).textSelection(.enabled)
                        }
                        HStack {
                            Button("Choose Data Folder…") { chooseDataRoot() }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([model.dataRoot])
                            }
                            Spacer()
                            Text("\(model.bottles.count) managed bottles • \(model.profiles.count) profiles")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Divider()
                        LabeledContent("Repository") {
                            Text(model.repoRoot.path).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 8)
                }

                GroupBox("Discovery & safety") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(model.discoveredBottles.count) bottles found across Basalt, Whisky, and CrossOver", systemImage: "shippingbox")
                        Label("\(model.steamGames.filter { !$0.isTool }.count) installed Steam games found", systemImage: "gamecontroller")
                        Label("External bottles are read-only until copied into Basalt", systemImage: "lock.shield")
                        Label("OpenComposite remains user-supplied", systemImage: "doc.badge.gearshape")
                    }
                    .padding(.top, 8)
                }
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Settings")
    }

    private func chooseDataRoot() {
        let panel = NSOpenPanel()
        panel.title = "Choose BasaltVR Data Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.dataRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.changeDataRoot(to: url) }
    }
}

private struct StreamSettingsControls: View {
    @Binding var settings: StreamLaunchSettings
    let audioDevices: [GameAudioDevice]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                Picker("Connection", selection: $settings.connection) {
                    ForEach(StreamConnectionMode.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                Stepper("\(settings.fps) fps", value: $settings.fps, in: 60...144)
                Stepper("\(settings.megabits) Mbps", value: $settings.megabits, in: 1...100)
            }
            GridRow {
                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(ResolutionSelection.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                Picker("Latency", selection: $settings.latency) {
                    Text("Balanced").tag(StreamLatencyPreset.balanced)
                    Text("Low").tag(StreamLatencyPreset.low)
                }
                Picker("Audio", selection: $settings.audioDeviceName) {
                    Text("Off").tag(String?.none)
                    ForEach(audioDevices, id: \.id) { device in
                        Text("\(device.name) • \(Int(device.sampleRate)) Hz")
                            .tag(String?.some(device.name))
                    }
                }
            }
        }
    }
}

private struct PerGameSettingsSheet: View {
    let profileName: String
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: StreamLaunchSettings

    init(profileName: String, model: BasaltAppModel) {
        self.profileName = profileName
        self.model = model
        _settings = State(initialValue: model.streamSettings(for: profileName))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Stream Settings").font(.title2.bold())
            Text(profileName).font(.headline).foregroundStyle(.secondary)
            StreamSettingsControls(settings: $settings, audioDevices: model.audioDevices)
            Text("Saving creates a per-game override. Reset uses the global defaults from Settings.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Reset to Global") {
                    model.resetStreamSettings(for: profileName)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.saveStreamSettings(settings, for: profileName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 720)
    }
}

private struct ProfileEditorSheet: View {
    let profile: LaunchProfile
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: LaunchSource
    @State private var executable: String
    @State private var workingDirectory: String
    @State private var arguments: String
    @State private var environment: String
    @State private var confirmingDelete = false

    init(profile: LaunchProfile, model: BasaltAppModel) {
        self.profile = profile
        self.model = model
        _source = State(initialValue: profile.source)
        _executable = State(initialValue: profile.executable)
        _workingDirectory = State(initialValue: profile.workingDirectory ?? "")
        _arguments = State(initialValue: profile.arguments.joined(separator: "\n"))
        _environment = State(initialValue: profile.environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Launch Profile").font(.title2.bold())
            Form {
                LabeledContent("Name", value: profile.name)
                LabeledContent("Bottle", value: profile.bottleName)
                Picker("Source", selection: $source) {
                    ForEach(LaunchSource.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
                TextField("Windows executable", text: $executable)
                TextField("Host working directory (optional)", text: $workingDirectory)
                LabeledContent("Arguments") {
                    TextEditor(text: $arguments).font(.body.monospaced()).frame(height: 90)
                }
                LabeledContent("Environment") {
                    TextEditor(text: $environment).font(.body.monospaced()).frame(height: 90)
                }
            }
            Text("Enter one argument or KEY=VALUE environment entry per line.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Delete Profile", role: .destructive) { confirmingDelete = true }
                Button("Install OpenComposite…") { installOpenComposite() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 700)
        .confirmationDialog(
            "Delete '\(profile.name)'?", isPresented: $confirmingDelete,
            titleVisibility: .visible) {
                Button("Delete Profile", role: .destructive) {
                    Task { await model.deleteProfile(profile.name); dismiss() }
                }
            } message: {
                Text("The bottle and installed game will not be removed.")
            }
    }

    private func save() {
        var values = [String: String]()
        for line in environment.components(separatedBy: .newlines) {
            guard let split = line.firstIndex(of: "="), split != line.startIndex else { continue }
            values[String(line[..<split])] = String(line[line.index(after: split)...])
        }
        let updated = LaunchProfile(
            name: profile.name, bottleName: profile.bottleName, source: source,
            executable: executable.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: arguments.components(separatedBy: .newlines).filter { !$0.isEmpty },
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
            environment: values)
        Task { await model.updateProfile(updated); dismiss() }
    }

    private func installOpenComposite() {
        guard let bottle = model.bottles.first(where: { $0.name == profile.bottleName }) else {
            model.alertMessage = "The managed bottle for this profile is missing."
            return
        }
        let dll = UTType(filenameExtension: "dll")!
        let sourcePanel = NSOpenPanel()
        sourcePanel.title = "Choose the OpenComposite openvr_api.dll"
        sourcePanel.allowedContentTypes = [dll]
        sourcePanel.allowsMultipleSelection = false
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }

        let targetPanel = NSSavePanel()
        targetPanel.title = "Choose the game's openvr_api.dll location"
        targetPanel.allowedContentTypes = [dll]
        targetPanel.nameFieldStringValue = "openvr_api.dll"
        targetPanel.directoryURL = URL(fileURLWithPath: bottle.prefixPath)
            .appendingPathComponent("drive_c", isDirectory: true)
        guard targetPanel.runModal() == .OK, let target = targetPanel.url else { return }
        Task {
            await model.installOpenComposite(
                profileName: profile.name, artifact: source, target: target)
        }
    }
}

private struct ImportBottleSheet: View {
    let bottle: DiscoveredBottle
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isCopying = false

    init(bottle: DiscoveredBottle, model: BasaltAppModel) {
        self.bottle = bottle
        self.model = model
        let lowered = bottle.name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        _name = State(initialValue: String((lowered.isEmpty ? "imported-bottle" : lowered).prefix(56)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy into Basalt").font(.title2.bold())
            Text("\(bottle.name) • \(bottle.origin.label)")
                .font(.headline).foregroundStyle(.secondary)
            TextField("Managed bottle name", text: $name)
            Label("The original prefix remains untouched.", systemImage: "lock.shield")
            Label("Files use APFS copy-on-write cloning when supported, so the initial copy is fast and space-efficient.", systemImage: "internaldrive")
            Label("Copying never launches Steam. Prepare installs Basalt DXMT and OpenXR afterward.", systemImage: "wrench.and.screwdriver")
            Text(bottle.prefix.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if isCopying {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Cloning the bottle into Basalt… Keep Basalt open until this finishes.")
                        .font(.callout)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isCopying)
                Button(isCopying ? "Copying…" : "Copy Bottle") {
                    let destination = name
                    isCopying = true
                    Task {
                        let succeeded = await model.importBottle(bottle, as: destination)
                        if succeeded {
                            dismiss()
                        } else {
                            isCopying = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || isCopying)
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled(isCopying)
    }
}

private enum GameCardSheet: Identifiable {
    case importBottle(DiscoveredBottle)
    case edit(LaunchProfile)
    case settings(String)

    var id: String {
        switch self {
        case .importBottle(let bottle): "import-\(bottle.id)"
        case .edit(let profile): "edit-\(profile.name)"
        case .settings(let profileName): "settings-\(profileName)"
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title).font(.title3.weight(.semibold))
            Text("\(count)").font(.caption.weight(.bold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: Double?
    let suffix: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(suffix).font(.caption).foregroundStyle(.secondary)
            }
            Rectangle().fill(color).frame(height: 3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct MetricChart: View {
    let title: String
    let samples: [StreamMetricSample]
    let keyPath: KeyPath<StreamMetricSample, Double?>
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Chart(samples) { sample in
                if let value = sample[keyPath: keyPath] {
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value(title, value))
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct PageHeader: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow)
                .font(.caption.weight(.bold))
                .tracking(1.3)
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}
