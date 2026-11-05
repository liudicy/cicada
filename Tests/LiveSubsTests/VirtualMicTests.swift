import Foundation
import Testing
@testable import LiveSubs

/// Serves a package that is not BlackHole.
final class FakePackage: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("not the driver".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor @Suite struct VirtualMicTests {
    @Test func pinnedPackageIsHTTPSAndAFullHash() {
        #expect(VirtualMicInstaller.packageURL.scheme == "https")
        #expect(VirtualMicInstaller.packageSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    }

    @Test func aPackageWithTheWrongHashIsNotInstalled() async throws {
        let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("LiveSubsMic/BlackHole2ch.pkg")
        try? FileManager.default.removeItem(at: pkg)
        let installer = VirtualMicInstaller()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakePackage.self]
        installer.session = URLSession(configuration: config)
        installer.install(verifyOnly: true)
        for _ in 0..<100 {
            if case .failed = installer.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(installer.state == .failed(L("安装包校验未通过，已中止安装")))
        #expect(!FileManager.default.fileExists(atPath: pkg.path))
    }
}
