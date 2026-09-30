import AppKit
import Darwin
import ImageIO

/// Observes the actual screenshot destination; never changes macOS shortcuts or
/// moves the user's originals. Disk reads run off the UI thread.
final class SystemCaptureMonitor: @unchecked Sendable {
    struct Snapshot: Sendable {
        var captures: [Capture]
        var added: [URL]
        var accessDenied: Bool
    }

    private let queue = DispatchQueue(label: "local.notchhub.system-captures", qos: .utility)
    private let directories: @Sendable () -> [URL]
    private let receive: @Sendable (Snapshot) -> Void
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var timer: DispatchSourceTimer?
    private var pending: [DispatchWorkItem] = []
    private var known = Set<URL>()
    private var started = false
    private var stopped = false
    private var lastCaptures: [Capture] = []
    private var lastAccessDenied = false
    private let startedAt = Date()

    init(directories: @escaping @Sendable () -> [URL] = { SystemCaptureMonitor.screenshotDirectories() },
         receive: @escaping @Sendable (Snapshot) -> Void) {
        self.directories = directories
        self.receive = receive
        queue.async { [weak self] in self?.start() }
    }

    func rescan() {
        queue.async { [weak self] in self?.scan() }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            pending.forEach { $0.cancel() }; pending.removeAll()
            sources.values.forEach { $0.cancel() }; sources.removeAll()
            timer?.cancel(); timer = nil
        }
    }

    private func start() {
        guard !stopped else { return }
        scan()
        // Also re-resolves a destination changed in ⇧⌘5, recreates deleted folder
        // watches and retries files whose metadata arrived after the directory event.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.scan() }
        self.timer = timer
        timer.resume()
    }

    private func directoryChanged() {
        pending.forEach { $0.cancel() }
        // A system screenshot is created before its pixels and metadata finish
        // writing. Retry short-lived partial files instead of permanently skipping them.
        pending = [0.25, 1.0, 2.5].map { delay in
            let work = DispatchWorkItem { [weak self] in self?.scan() }
            queue.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func scan() {
        guard !stopped else { return }
        let folders = Set(directories().map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        for folder in Set(sources.keys).subtracting(folders) {
            sources.removeValue(forKey: folder)?.cancel()
        }
        var captures: [Capture] = []
        var denied = false
        let validated = Dictionary(lastCaptures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for folder in folders {
            if sources[folder] == nil {
                let descriptor = open(folder.path, O_EVTONLY | O_CLOEXEC)
                if descriptor >= 0 {
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                        eventMask: [.write, .attrib, .rename, .delete, .revoke], queue: queue)
                    source.setEventHandler { [weak self] in
                        guard let self else { return }
                        if let events = self.sources[folder]?.data, !events.intersection([.rename, .delete, .revoke]).isEmpty {
                            self.sources.removeValue(forKey: folder)?.cancel()
                        }
                        self.directoryChanged()
                    }
                    source.setCancelHandler { close(descriptor) }
                    sources[folder] = source
                    source.resume()
                }
            }
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: Capture.fileKeys, options: [.skipsHiddenFiles])
                captures += urls.compactMap { Capture.read($0, systemOnly: true, previouslyValidated: validated[$0.standardizedFileURL]) }
            } catch {
                let error = error as NSError
                denied = denied || error.code == NSFileReadNoPermissionError
                    || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code))
            }
        }
        captures.sort(by: Capture.newestFirst)
        let ids = Set(captures.map(\.id))
        let added = started ? captures.filter { !known.contains($0.id) && $0.date >= startedAt }.map(\.url) : []
        known.formUnion(ids)
        if !started || captures != lastCaptures || denied != lastAccessDenied {
            receive(Snapshot(captures: captures, added: added, accessDenied: denied))
            lastCaptures = captures
            lastAccessDenied = denied
        }
        started = true
    }

    static func screenshotDirectories() -> [URL] {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let location = CFPreferencesCopyAppValue("location" as CFString, domain) as? String,
              !location.isEmpty else { return [desktop] }
        let path = (location as NSString).expandingTildeInPath
        let configured = location.hasPrefix("file://") ? URL(string: location) : URL(fileURLWithPath: path, isDirectory: true)
        guard let configured, configured.isFileURL else { return [desktop] }
        return [configured]
    }

    static func isSystemScreenshot(_ url: URL) -> Bool {
        // Read the metadata attached by Screenshot directly: no dependence on
        // localized filenames, Spotlight indexing, or keyboard interception.
        let key = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 4096 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, key, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        guard read == size,
              let value = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil) else { return false }
        return (value as? NSNumber)?.boolValue == true
    }
}
