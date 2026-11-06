// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QianLiYan",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "QianLiYan", targets: ["QianLiYan"])],
    targets: [
        .target(name: "SearchCore"),
        .executableTarget(name: "ScanWorker", dependencies: ["SearchCore"]),
        .executableTarget(name: "QianLiYan", dependencies: ["SearchCore"]),
        .executableTarget(name: "SearchVerification", dependencies: ["SearchCore"], path: "Tests/SearchVerification"),
        .executableTarget(name: "QuickSearchVerification", dependencies: ["SearchCore"], path: "Tests/QuickSearchVerification")
    ]
)
