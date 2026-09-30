import Foundation

/// Event-driven local MediaRemote reader. No network access or metadata persistence.
final class NowPlayingBridge {
    var received: (([String: Any]) -> Void)?
    var disconnected: (() -> Void)?
    private var process: Process?
    private var output: Pipe?
    private var pending = Data()
    private let queue = DispatchQueue(label: "Touch.NowPlaying.Stream", qos: .utility)
    private var paths: (String, String)? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/MediaRemoteAdapter.framework").path
        guard FileManager.default.fileExists(atPath: script), FileManager.default.fileExists(atPath: framework) else { return nil }
        return (script, framework)
    }
    @discardableResult func start() -> Bool {
        guard process == nil, let paths else { return false }
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [paths.0, paths.1, "stream", "--no-diff", "--micros", "--debounce=150"]
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in self?.consume(bytes) }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.process = nil; self?.disconnected?() }
        }
        do { try task.run(); process = task; output = pipe; return true }
        catch { pipe.fileHandleForReading.readabilityHandler = nil; return false }
    }
    func stop() {
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; output = nil
    }
    func send(_ command: Int) {
        guard [0,1,2,4,5].contains(command), let paths else { return }
        queue.async {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            task.arguments = [paths.0, paths.1, "send", String(command)]
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { if task.isRunning { task.terminate() } }
            } catch { }
        }
    }
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        guard let micros = PlaybackPosition.microseconds(seconds), let paths else {
            completion(false); return
        }
        queue.async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            task.arguments = [paths.0, paths.1, "seek", String(micros)]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { process in
                DispatchQueue.main.async { completion(process.terminationStatus == 0) }
            }
            do {
                try task.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                    if task.isRunning { task.terminate() }
                }
            } catch { DispatchQueue.main.async { completion(false) } }
        }
    }
    private func consume(_ bytes: Data) {
        pending.append(bytes)
        guard pending.count < 8_000_000 else { pending.removeAll(keepingCapacity: false); return }
        while let end = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: end); pending.removeSubrange(...end)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], json["type"] as? String == "data", let payload = json["payload"] as? [String: Any] else { continue }
            DispatchQueue.main.async { [weak self] in self?.received?(payload) }
        }
    }
    deinit { stop() }
}
