import XCTest
@testable import WoWSiliconSwift

final class ServerManagerServiceTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    func testInstallSetupFilesWritesLauncherAndRootRealmlist() throws {
        let serverURL = try makeTemporaryDirectory()
        let gameURL = try makeTemporaryDirectory()
        try "".write(to: serverURL.appendingPathComponent("docker-compose.yml"), atomically: true, encoding: .utf8)

        let result = try ServerManagerService.installSetupFiles(serverPath: serverURL.path, gamePath: gameURL.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.launcherPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.realmlistPath))
        XCTAssertEqual(try String(contentsOfFile: result.realmlistPath, encoding: .utf8), "set realmlist 127.0.0.1\n")
        XCTAssertEqual(URL(fileURLWithPath: result.realmlistPath).lastPathComponent, "realmlist.wtf")
    }

    func testInstallSetupFilesPrefersLocaleRealmlistWhenPresent() throws {
        let serverURL = try makeTemporaryDirectory()
        let gameURL = try makeTemporaryDirectory()
        let localeRealmlist = gameURL
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("enUS", isDirectory: true)
            .appendingPathComponent("realmlist.wtf")

        try FileManager.default.createDirectory(at: localeRealmlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "set realmlist old.realm\n".write(to: localeRealmlist, atomically: true, encoding: .utf8)
        try "".write(to: serverURL.appendingPathComponent("docker-compose.yml"), atomically: true, encoding: .utf8)

        let result = try ServerManagerService.installSetupFiles(serverPath: serverURL.path, gamePath: gameURL.path)

        XCTAssertEqual(URL(fileURLWithPath: result.realmlistPath).standardizedFileURL.path, localeRealmlist.standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: localeRealmlist, encoding: .utf8), "set realmlist 127.0.0.1\n")
    }

    func testInstallSetupFilesFailsWhenComposeMissing() throws {
        let serverURL = try makeTemporaryDirectory()
        let gameURL = try makeTemporaryDirectory()

        do {
            _ = try ServerManagerService.installSetupFiles(serverPath: serverURL.path, gamePath: gameURL.path)
            XCTFail("Expected compose validation failure")
        } catch let error as ServerManagerError {
            guard case .composeFileMissing = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }
}
