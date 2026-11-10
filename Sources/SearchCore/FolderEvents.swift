import Foundation
import CoreServices

final class FolderEvents {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "filesight.folder-events")
    private final class Handler {
        let receive: ([String], Bool, UInt64) -> Void
        init(_ receive: @escaping ([String], Bool, UInt64) -> Void) { self.receive = receive }
    }
    private let handler: Handler

    init(receive: @escaping ([String], Bool, UInt64) -> Void) { self.handler = Handler(receive) }

    static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    func start(paths: [String], since eventID: UInt64 = UInt64(kFSEventStreamEventIdSinceNow)) -> Bool {
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
        guard let stream = FSEventStreamCreate(nil, { _, context, count, rawPaths, flags, eventIDs in
            guard let context else { return }
            let watcher = Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let uncertain = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged |
                kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount |
                kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            var changed: [String] = []
            var rebuild = paths.count != count
            var latest: UInt64 = 0
            for (offset, path) in paths.prefix(count).enumerated() {
                if flags[offset] & UInt32(uncertain) != 0 { rebuild = true }
                changed.append(path)
                latest = max(latest, eventIDs[offset])
            }
            watcher.receive(changed, rebuild, latest)
        }, &context, paths as CFArray, FSEventStreamEventId(eventID), 0.2, UInt32(options)) else { return false }
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
