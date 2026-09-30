import AppKit
import Combine
import Darwin

enum MacFamily: String, CaseIterable, Identifiable, Codable {
    case pro14, pro16, air13, air15, pro13, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pro14: return "MacBook Pro 14″"
        case .pro16: return "MacBook Pro 16″"
        case .air13: return "MacBook Air 13″"
        case .air15: return "MacBook Air 15″"
        case .pro13: return "MacBook Pro 13″"
        case .other: return "Другой Mac"
        }
    }
    // Friendly labels only. Panel dimensions always come from NSScreen.
    // Apple model identifiers: review/mac-setup-sources.md.
    static func identify(_ model: String) -> Self? {
        let catalog: [(Self, Set<String>)] = [
            (.pro14, ["MacBookPro18,3", "MacBookPro18,4", "Mac14,5", "Mac14,9", "Mac15,3", "Mac15,6", "Mac15,8", "Mac15,10", "Mac16,1", "Mac16,6", "Mac16,8", "Mac17,2", "Mac17,7", "Mac17,9"]),
            (.pro16, ["MacBookPro16,1", "MacBookPro16,4", "MacBookPro18,1", "MacBookPro18,2", "Mac14,6", "Mac14,10", "Mac15,7", "Mac15,9", "Mac15,11", "Mac16,5", "Mac16,7", "Mac17,6", "Mac17,8"]),
            (.air13, ["MacBookAir8,1", "MacBookAir8,2", "MacBookAir9,1", "MacBookAir10,1", "Mac14,2", "Mac15,12", "Mac16,12", "Mac17,3"]),
            (.air15, ["Mac14,15", "Mac15,13", "Mac16,13", "Mac17,4"]),
            (.pro13, ["MacBookPro15,2", "MacBookPro15,4", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro17,1", "Mac14,7"])
        ]
        return catalog.first { $0.1.contains(model) }?.0
    }
}

struct MacDisplay {
    let name: String
    let frame: NSRect
    let topInset: CGFloat
    let left: NSRect?
    let right: NSRect?
    var geometry: NotchGeometry { NotchGeometry(screen: frame, topInset: topInset, left: left, right: right) }
    var hasNotch: Bool { geometry.hasMeasuredNotch }
}

struct MacSnapshot {
    let identifier: String
    let display: MacDisplay?
    var family: MacFamily? { MacFamily.identify(identifier) }
}

@MainActor
enum MacHardware {
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.screens.first(where: {
                guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayIsBuiltin(id.uint32Value) != 0
            }) ?? NSScreen.main ?? NSScreen.screens.first
    }
    static func read() -> MacSnapshot {
        var size = 0
        var identifier = ""
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size < 256 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 { identifier = String(cString: buffer) }
        }
        let display = preferredScreen().map {
            MacDisplay(name: $0.localizedName, frame: $0.frame, topInset: $0.safeAreaInsets.top,
                left: $0.auxiliaryTopLeftArea, right: $0.auxiliaryTopRightArea)
        }
        return MacSnapshot(identifier: identifier, display: display)
    }
}

enum MacVerification: Equatable {
    case confirmed, mismatch, unrecognized, noDisplay
    static func evaluate(selected: MacFamily, snapshot: MacSnapshot) -> Self {
        guard snapshot.display != nil else { return .noDisplay }
        guard let detected = snapshot.family else { return .unrecognized }
        return detected == selected ? .confirmed : .mismatch
    }
    var canContinue: Bool { self == .confirmed || self == .unrecognized }
}

@MainActor
final class MacSetup: ObservableObject {
    enum Stage: Equatable { case choose, checking, result }
    static let completedKey = "touch.macSetup.version"
    static let version = 1
    @Published var selected: MacFamily
    @Published private(set) var snapshot: MacSnapshot
    @Published private(set) var stage: Stage = .choose
    @Published private(set) var verification: MacVerification = .unrecognized
    private let defaults: UserDefaults
    private let readHardware: () -> MacSnapshot
    private var task: Task<Void, Never>?
    var onComplete: (() -> Void)?

    init(defaults: UserDefaults = .standard, readHardware: (() -> MacSnapshot)? = nil) {
        self.defaults = defaults; self.readHardware = readHardware ?? { MacHardware.read() }
        let current = self.readHardware()
        snapshot = current
        selected = current.family ?? .other
    }
    static func needsSetup(_ defaults: UserDefaults = .standard) -> Bool { defaults.integer(forKey: completedKey) < version }
    func verify(animated: Bool = true) {
        task?.cancel()
        if !animated { finishVerification(); return }
        stage = .checking
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.finishVerification()
        }
    }
    private func finishVerification() {
        snapshot = readHardware()
        verification = .evaluate(selected: selected, snapshot: snapshot)
        stage = .result
    }
    func chooseAgain() { task?.cancel(); stage = .choose }
    func useDetected() { if let detected = snapshot.family { selected = detected }; verify() }
    func cancel() { task?.cancel() }
    @discardableResult func complete() -> Bool {
        guard stage == .result, verification.canContinue else { return false }
        // Recheck if a monitor changed while the result was on screen.
        finishVerification()
        guard verification.canContinue else { return false }
        defaults.set(Self.version, forKey: Self.completedKey)
        defaults.set(selected.rawValue, forKey: "touch.macSetup.selectedFamily")
        onComplete?()
        return true
    }
}
