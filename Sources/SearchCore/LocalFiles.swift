import Foundation
import Darwin

public enum LocalFiles {
    public static var userHome: URL {
        // NSHomeDirectory is the app container when App Sandbox is enabled.
        if let home = getpwuid(getuid())?.pointee.pw_dir { return URL(fileURLWithPath: String(cString: home), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func isLocal(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.volumeIsLocalKey])
        // Unknown volume locality must not silently allow a network filesystem.
        return values.volumeIsLocal == true
    }
}
