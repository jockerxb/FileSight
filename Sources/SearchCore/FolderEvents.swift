import Foundation
import CoreServices

final class FolderEvents {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "filesight.folder-events")
    private final class Handler {
        let receive: ([String], Bool) -> Void
        init(_ receive: @escaping ([String], Bool) -> Void) { self.receive = receive }
    }
    private let handler: Handler

    init(receive: @escaping ([String], Bool) -> Void) { self.handler = Handler(receive) }

    func start(paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Handler>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<Handler>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let options = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(nil, { _, context, count, rawPaths, flags, _ in
            guard let context else { return }
            let watcher = Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let uncertain = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged |
                kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
            var changed: [String] = []
            var rebuild = paths.count != count
            for (offset, path) in paths.prefix(count).enumerated() {
                if flags[offset] & UInt32(uncertain) != 0 { rebuild = true }
                changed.append(path)
            }
            watcher.receive(changed, rebuild)
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.35, UInt32(options)) else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
    }
}
