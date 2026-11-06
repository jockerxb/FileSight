import Foundation
import SearchCore
import Darwin

// Parent crashes and normal App termination must not leave blocked workers alive.
let parent = getppid()
let parentWatch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
parentWatch.schedule(deadline: .now() + 1, repeating: 1)
parentWatch.setEventHandler { if getppid() != parent { exit(0) } }
parentWatch.resume()

while let line = readLine() {
    do {
        let request = try JSONDecoder().decode(ScanRequest.self, from: Data(line.utf8))
        try autoreleasepool {
            try DirectoryScanner.scan(request) { response in
                var data = try JSONEncoder().encode(response); data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            }
        }
    } catch {
        // A broken protocol is a failed worker, never an empty successful search.
        exit(1)
    }
}
