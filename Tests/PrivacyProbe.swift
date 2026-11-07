// Test-only executable. Never bundled into 千里眼.app.
import Foundation
import Darwin

let args = CommandLine.arguments
let folder = args[1]
let port = UInt16(args[2])!
let fixture = folder + "/document.txt"
var checks: [String: Bool] = [:]
let readable = open(fixture, O_RDONLY)
let expectRead = !args.contains("deny-read")
checks["readPolicyPassed"] = expectRead ? readable >= 0 : readable < 0 && (errno == EPERM || errno == EACCES)
if readable >= 0 { close(readable) }
let write = open(fixture, O_WRONLY | O_TRUNC)
checks["overwriteDenied"] = write < 0 && errno == EPERM
if write >= 0 { close(write) }
let create = open(folder + "/new.txt", O_WRONLY | O_CREAT, 0o600)
checks["createDenied"] = create < 0 && errno == EPERM
if create >= 0 { close(create) }
let moved = folder + "/moved.txt"
let renamed = rename(fixture, moved)
checks["renameDenied"] = renamed != 0 && errno == EPERM
if renamed == 0 { _ = rename(moved, fixture) }
let removed = unlink(fixture)
checks["deleteDenied"] = removed != 0 && errno == EPERM
let sock = socket(AF_INET, SOCK_STREAM, 0)
if sock < 0 { checks["networkDenied"] = errno == EPERM }
else {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    checks["networkDenied"] = connected != 0 && errno == EPERM
    close(sock)
}
if args.count > 3 && args[3] == "parent" {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: args[0]).deletingLastPathComponent().appendingPathComponent("ChildProbe")
    child.arguments = [folder, args[2]] + (expectRead ? [] : ["deny-read"])
    let output = Pipe(); child.standardOutput = output
    try child.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    let childChecks = try JSONDecoder().decode([String:Bool].self, from: data)
    checks["childPolicyPassed"] = child.terminationStatus == 0 && childChecks.values.allSatisfy { $0 }
}
let data = try JSONEncoder().encode(checks)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
