import SwiftUI
import AppKit
import Combine
import UserNotifications
import ServiceManagement

// MARK: - App Entry

@main
struct DesktopPlantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var plantView: PlantMenuBarView!
    let vm = PlantViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Register to launch at login
        try? SMAppService.mainApp.register()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true

        if let button = statusItem.button {
            plantView = PlantMenuBarView(frame: NSRect(x: 0, y: 0, width: 28, height: 22))
            plantView.vm = vm
            button.frame = NSRect(x: 0, y: 0, width: 28, height: 22)
            button.addSubview(plantView)
            button.action = #selector(openMenu)
            button.target = self
        }

        vm.start()

        // Show target setup on first launch
        if !vm.hasTarget {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                TargetWindowController.shared.show(vm: self.vm)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                  willPresent notification: UNNotification,
                                  withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
        DispatchQueue.main.async {
            self.vm.needsCare = true
            self.vm.playWaterSound()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                  didReceive response: UNNotificationResponse,
                                  withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.vm.needsCare = true }
        completionHandler()
    }

    // MARK: - Menu

    @objc func openMenu() {
        let menu = NSMenu()

        if !vm.hasTarget {
            let item = NSMenuItem(title: "🌱 Set your growth target…", action: #selector(showTargetWindow), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            // Stage name
            let stageItem = NSMenuItem(title: "🌱  \(vm.stageDescription)", action: nil, keyEquivalent: "")
            stageItem.isEnabled = false
            menu.addItem(stageItem)

            // Overall progress bar  e.g.  ████░░░░░░  42 / 100
            let overallBar = progressBar(value: vm.overallProgress, width: 14)
            let overallItem = NSMenuItem(
                title: "   \(overallBar)  \(vm.totalCares)/\(vm.totalTarget)",
                action: nil, keyEquivalent: "")
            overallItem.isEnabled = false
            menu.addItem(overallItem)

            // Stage progress
            if vm.stage != .bloom {
                let stageBar  = progressBar(value: vm.stageProgress, width: 14)
                let stageInfo = NSMenuItem(
                    title: "   Stage  \(stageBar)  → \(vm.nextStageDescription)",
                    action: nil, keyEquivalent: "")
                stageInfo.isEnabled = false
                menu.addItem(stageInfo)

                let left = vm.caresLeftInStage
                let hint = NSMenuItem(
                    title: "   \(left) care\(left == 1 ? "" : "s") to \(vm.nextStageDescription)",
                    action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            }

            menu.addItem(.separator())

            // Care — enabled whenever there are reminders (reminder fires set needsCare,
            // but user may open menu before seeing the banner)
            let careTitle = vm.needsCare ? "💧  Care for plant  ●" : "💧  Care for plant"
            let careItem = NSMenuItem(title: careTitle, action: #selector(carePlant), keyEquivalent: "c")
            careItem.target = self
            careItem.isEnabled = !vm.reminders.isEmpty
            menu.addItem(careItem)

            menu.addItem(.separator())

            // Reminders
            let remHeader = NSMenuItem(title: "⏰  Reminders", action: nil, keyEquivalent: "")
            remHeader.isEnabled = false
            menu.addItem(remHeader)

            let addRem = NSMenuItem(title: "   Add reminder…", action: #selector(showReminderWindow), keyEquivalent: "r")
            addRem.target = self
            menu.addItem(addRem)

            for r in vm.reminders {
                let item = NSMenuItem(title: "   \(r.displayString)  ✕",
                                      action: #selector(removeReminder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = r.id.uuidString
                menu.addItem(item)
            }

            menu.addItem(.separator())

            let resetItem = NSMenuItem(title: "Reset target…", action: #selector(showTargetWindow), keyEquivalent: "")
            resetItem.target = self
            menu.addItem(resetItem)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        self.statusItem.menu = menu
        self.statusItem.button?.performClick(nil)
        DispatchQueue.main.async { self.statusItem.menu = nil }
    }

    @objc func carePlant()        { vm.care() }
    @objc func showReminderWindow() { ReminderWindowController.shared.show(vm: vm) }
    @objc func showTargetWindow()   { TargetWindowController.shared.show(vm: vm) }

    @objc func removeReminder(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let uuid = UUID(uuidString: idStr) else { return }
        vm.removeReminder(id: uuid)
    }

    private func progressBar(value: Double, width: Int) -> String {
        let filled = Int((value * Double(width)).rounded())
        let empty  = max(0, width - filled)
        return String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
    }
}

// MARK: - Growth Model

struct GrowthThresholds {
    let sprout:   Int   // cares to reach sprout   (cumulative)
    let seedling: Int   // cares to reach seedling (cumulative)
    let plant:    Int   // cares to reach plant    (cumulative)
    let bloom:    Int   // cares to reach bloom    (cumulative)

    // Build cumulative thresholds from per-stage inputs
    static func from(sproutCares: Int, seedlingCares: Int, plantCares: Int, bloomCares: Int) -> GrowthThresholds {
        let s = max(1, sproutCares)
        let se = s + max(1, seedlingCares)
        let p  = se + max(1, plantCares)
        let b  = p  + max(1, bloomCares)
        return GrowthThresholds(sprout: s, seedling: se, plant: p, bloom: b)
    }
}

// MARK: - PlantViewModel

enum PlantStage: Int, Codable { case seed = 0, sprout, seedling, plant, bloom }

class PlantViewModel: ObservableObject {
    @Published var stage:         PlantStage = .seed
    @Published var totalCares:    Int        = 0
    @Published var swayPhase:     CGFloat    = 0
    @Published var needsCare:     Bool       = false
    @Published var isCelebrating: Bool       = false
    @Published var reminders:     [PlantReminder] = []

    // Per-stage care counts set by user (0 = not configured yet)
    @Published var sproutCares:   Int = 0
    @Published var seedlingCares: Int = 0
    @Published var plantCares:    Int = 0
    @Published var bloomCares:    Int = 0

    private var swayTimer:      Timer?
    private var celebrateTimer: Timer?

    var hasTarget: Bool { sproutCares > 0 }

    var thresholds: GrowthThresholds {
        .from(sproutCares: sproutCares, seedlingCares: seedlingCares,
              plantCares: plantCares,   bloomCares: bloomCares)
    }

    var totalTarget: Int { thresholds.bloom }

    // 0.0–1.0 overall journey
    var overallProgress: Double {
        guard hasTarget else { return 0 }
        return min(1.0, Double(totalCares) / Double(totalTarget))
    }

    // 0.0–1.0 within current stage
    var stageProgress: Double {
        guard hasTarget, stage != .bloom else { return 1.0 }
        let t = thresholds
        let (start, end): (Int, Int)
        switch stage {
        case .seed:     start = 0;        end = t.sprout
        case .sprout:   start = t.sprout; end = t.seedling
        case .seedling: start = t.seedling; end = t.plant
        case .plant:    start = t.plant;  end = t.bloom
        case .bloom:    return 1.0
        }
        let width = end - start
        guard width > 0 else { return 1.0 }
        return min(1.0, Double(totalCares - start) / Double(width))
    }

    var caresLeftInStage: Int {
        guard hasTarget, stage != .bloom else { return 0 }
        let t = thresholds
        switch stage {
        case .seed:     return max(0, t.sprout   - totalCares)
        case .sprout:   return max(0, t.seedling - totalCares)
        case .seedling: return max(0, t.plant    - totalCares)
        case .plant:    return max(0, t.bloom    - totalCares)
        case .bloom:    return 0
        }
    }

    var stageDescription: String {
        switch stage {
        case .seed:     return "Seed"
        case .sprout:   return "Sprout"
        case .seedling: return "Seedling"
        case .plant:    return "Plant"
        case .bloom:    return "Blooming! 🌸"
        }
    }

    var nextStageDescription: String {
        switch stage {
        case .seed:     return "Sprout"
        case .sprout:   return "Seedling"
        case .seedling: return "Plant"
        case .plant:    return "Bloom"
        case .bloom:    return "—"
        }
    }

    // MARK: - Lifecycle

    func start() {
        loadState()
        swayTimer = Timer(timeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let speed: CGFloat = self.needsCare ? 0.05 : (self.isCelebrating ? 0.20 : 0.06)
            self.swayPhase += speed
        }
        RunLoop.main.add(swayTimer!, forMode: .common)
    }

    func setTargets(sprout: Int, seedling: Int, plant: Int, bloom: Int) {
        sproutCares   = max(1, sprout)
        seedlingCares = max(1, seedling)
        plantCares    = max(1, plant)
        bloomCares    = max(1, bloom)
        totalCares    = 0
        stage         = .seed
        saveState()
    }

    func care() {
        guard stage != .bloom else { return }
        needsCare     = false
        isCelebrating = true
        totalCares   += 1
        playWaterSound()

        let t = thresholds
        let newStage: PlantStage
        switch totalCares {
        case ..<t.sprout:   newStage = .seed
        case ..<t.seedling: newStage = .sprout
        case ..<t.plant:    newStage = .seedling
        case ..<t.bloom:    newStage = .plant
        default:            newStage = .bloom
        }
        stage = newStage
        saveState()

        celebrateTimer?.invalidate()
        celebrateTimer = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.isCelebrating = false
        }
        RunLoop.main.add(celebrateTimer!, forMode: .common)
    }

    // MARK: - Reminders

    func addReminder(_ reminder: PlantReminder) {
        var r = reminder
        scheduleNotifications(for: &r)
        reminders.append(r)
    }

    func removeReminder(id: UUID) {
        if let r = reminders.first(where: { $0.id == id }) {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: r.notificationIDs)
        }
        reminders.removeAll { $0.id == id }
    }

    private func scheduleNotifications(for reminder: inout PlantReminder) {
        let center = UNUserNotificationCenter.current()
        var ids: [String] = []
        let content = UNMutableNotificationContent()
        content.title = "🌱 \(reminder.label)"
        content.body  = "Your plant needs care!"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("Drop.aiff"))

        switch reminder.frequency {
        case .once:
            let comps = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from: reminder.time)
            let id = UUID().uuidString
            center.add(UNNotificationRequest(identifier: id, content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            ids.append(id)
        case .daily:
            let comps = Calendar.current.dateComponents([.hour,.minute], from: reminder.time)
            let id = UUID().uuidString
            center.add(UNNotificationRequest(identifier: id, content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
            ids.append(id)
        case .weekly:
            let comps = Calendar.current.dateComponents([.weekday,.hour,.minute], from: reminder.time)
            let id = UUID().uuidString
            center.add(UNNotificationRequest(identifier: id, content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
            ids.append(id)
        case .custom:
            let id = UUID().uuidString
            center.add(UNNotificationRequest(identifier: id, content: content,
                        trigger: UNTimeIntervalNotificationTrigger(
                            timeInterval: TimeInterval(reminder.intervalHours * 3600), repeats: true)))
            ids.append(id)
        }
        reminder.notificationIDs = ids
    }

    // MARK: - Sound

    func playWaterSound() {
        // "Drop" is the closest built-in macOS sound to a water droplet
        // Falls back to "Tink" if not found
        let sound = NSSound(named: "Drop") ?? NSSound(named: "Tink")
        sound?.volume = 0.7
        sound?.play()
    }

    // MARK: - Persistence

    private func saveState() {
        UserDefaults.standard.set(stage.rawValue,  forKey: "plant.stage")
        UserDefaults.standard.set(totalCares,      forKey: "plant.totalCares")
        UserDefaults.standard.set(sproutCares,     forKey: "plant.sproutCares")
        UserDefaults.standard.set(seedlingCares,   forKey: "plant.seedlingCares")
        UserDefaults.standard.set(plantCares,      forKey: "plant.plantCares")
        UserDefaults.standard.set(bloomCares,      forKey: "plant.bloomCares")
    }

    private func loadState() {
        sproutCares   = UserDefaults.standard.integer(forKey: "plant.sproutCares")
        seedlingCares = UserDefaults.standard.integer(forKey: "plant.seedlingCares")
        plantCares    = UserDefaults.standard.integer(forKey: "plant.plantCares")
        bloomCares    = UserDefaults.standard.integer(forKey: "plant.bloomCares")
        totalCares    = UserDefaults.standard.integer(forKey: "plant.totalCares")
        let s         = UserDefaults.standard.integer(forKey: "plant.stage")
        stage         = PlantStage(rawValue: s) ?? .seed
    }
}

// MARK: - Reminder Model

enum ReminderFrequency: String, CaseIterable {
    case once = "Once", daily = "Daily", weekly = "Weekly", custom = "Custom (hours)"
}

struct PlantReminder: Identifiable {
    let id: UUID
    var label: String
    var frequency: ReminderFrequency
    var time: Date
    var intervalHours: Int
    var notificationIDs: [String] = []

    var displayString: String {
        let tf = DateFormatter(); tf.timeStyle = .short
        tf.dateStyle = frequency == .once ? .short : .none
        switch frequency {
        case .once:   return "\(label) — once \(tf.string(from: time))"
        case .daily:  return "\(label) — daily \(tf.string(from: time))"
        case .weekly: return "\(label) — weekly \(tf.string(from: time))"
        case .custom: return "\(label) — every \(intervalHours)h"
        }
    }
}

// MARK: - Target Setup Window

class TargetWindowController: NSObject {
    static let shared = TargetWindowController()
    var window: NSWindow?

    func show(vm: PlantViewModel) {
        window?.close()
        let view = TargetSetupView(vm: vm) { [weak self] in self?.window?.close() }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 380)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window?.title = "🌱 Set Growth Targets"
        window?.contentView = hosting
        window?.center()
        window?.isReleasedWhenClosed = false
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct TargetSetupView: View {
    @ObservedObject var vm: PlantViewModel
    var onDone: () -> Void

    @State private var sprout:   String = "5"
    @State private var seedling: String = "10"
    @State private var plant:    String = "15"
    @State private var bloom:    String = "20"

    var allValid: Bool {
        [sprout, seedling, plant, bloom].allSatisfy { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 >= 1 }
    }

    var totalCares: Int {
        [sprout, seedling, plant, bloom]
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            VStack(alignment: .leading, spacing: 4) {
                Text("How many cares per stage?")
                    .font(.headline)
                Text("Each stage unlocks after you care for your plant the set number of times.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 10) {
                stageRow(emoji: "🌱", name: "Seed → Sprout",
                         desc: "First shoot breaks through", value: $sprout)
                stageRow(emoji: "🪴", name: "Sprout → Seedling",
                         desc: "Roots establish, leaves form", value: $seedling)
                stageRow(emoji: "🌿", name: "Seedling → Plant",
                         desc: "Full structure grows", value: $plant)
                stageRow(emoji: "🌸", name: "Plant → Bloom",
                         desc: "Flowering, peak life", value: $bloom)
            }

            Text("Total: \(totalCares) cares to full bloom")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                    .keyboardShortcut(.escape)
                    .disabled(!vm.hasTarget)
                Button("Start Growing 🌱") {
                    vm.setTargets(
                        sprout:   Int(sprout)   ?? 5,
                        seedling: Int(seedling) ?? 10,
                        plant:    Int(plant)    ?? 15,
                        bloom:    Int(bloom)    ?? 20
                    )
                    onDone()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!allValid)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            if vm.hasTarget {
                sprout   = "\(vm.sproutCares)"
                seedling = "\(vm.seedlingCares)"
                plant    = "\(vm.plantCares)"
                bloom    = "\(vm.bloomCares)"
            }
        }
    }

    private func stageRow(emoji: String, name: String, desc: String, value: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(emoji).font(.title2).frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(.body, weight: .medium))
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .multilineTextAlignment(.center)
            Text("cares").font(.caption).foregroundColor(.secondary).frame(width: 36)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Reminder Window

class ReminderWindowController: NSObject {
    static let shared = ReminderWindowController()
    var window: NSWindow?
    weak var vm: PlantViewModel?

    func show(vm: PlantViewModel) {
        self.vm = vm
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let view = ReminderSetupView(vm: vm!) { [weak self] in self?.window?.close() }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 300)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window?.title = "🌱 Add Reminder"
        window?.contentView = hosting
        window?.center()
        window?.isReleasedWhenClosed = false
    }
}

// MARK: - Reminder Setup View

struct ReminderSetupView: View {
    @ObservedObject var vm: PlantViewModel
    var onDone: () -> Void

    @State private var label: String = "Water plant"
    @State private var frequency: ReminderFrequency = .daily
    @State private var time: Date = {
        var c = Calendar.current.dateComponents([.hour,.minute], from: Date())
        c.hour = 9; c.minute = 0
        return Calendar.current.date(from: c) ?? Date()
    }()
    @State private var intervalHours: Int = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Reminder").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Label").font(.caption).foregroundColor(.secondary)
                TextField("e.g. Water plant", text: $label).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Frequency").font(.caption).foregroundColor(.secondary)
                Picker("", selection: $frequency) {
                    ForEach(ReminderFrequency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }

            if frequency == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every \(intervalHours) hours").font(.caption).foregroundColor(.secondary)
                    Slider(value: Binding(get: { Double(intervalHours) }, set: { intervalHours = Int($0) }),
                           in: 1...72, step: 1)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(frequency == .once ? "Date & Time" : "Time").font(.caption).foregroundColor(.secondary)
                    DatePicker("", selection: $time,
                               displayedComponents: frequency == .once ? [.date,.hourAndMinute] : .hourAndMinute)
                        .labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onDone() }.keyboardShortcut(.escape)
                Button("Add Reminder") {
                    vm.addReminder(PlantReminder(id: UUID(), label: label,
                                                frequency: frequency, time: time,
                                                intervalHours: intervalHours))
                    onDone()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 340)
    }
}
