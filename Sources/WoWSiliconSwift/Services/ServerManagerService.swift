import Foundation

enum ServerManagerError: LocalizedError {
    case serverPathMissing
    case serverPathNotFound(String)
    case gamePathMissing
    case gamePathNotFound(String)
    case composeFileMissing(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverPathMissing:
            return "Server folder is not set."
        case .serverPathNotFound(let path):
            return "Server folder not found at \(path)."
        case .gamePathMissing:
            return "Game path is not set."
        case .gamePathNotFound(let path):
            return "Game path not found at \(path)."
        case .composeFileMissing(let path):
            return "docker-compose.yml was not found in \(path)."
        case .commandFailed(let details):
            return details
        }
    }
}

struct ServerSetupInstallResult {
    let launcherPath: String
    let realmlistPath: String
}

enum ServerRuntimeState {
    case notConfigured
    case running
    case stopped
    case error
}

enum ServerManagerService {
    private static let launcherScriptName = "wow-vanilla-launcher.sh"
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static func installSetupFiles(serverPath: String, gamePath: String) throws -> ServerSetupInstallResult {
        let serverURL = try validatedServerDirectory(from: serverPath)
        _ = try validatedGameDirectory(from: gamePath)
        try ensureComposeExists(at: serverURL)

        let launcherURL = home.appendingPathComponent(launcherScriptName, isDirectory: false)
        try writeLauncherScript(serverDirectory: serverURL.path, to: launcherURL)

        let realmlistURL = try writeRealmlist(gamePath: gamePath)
        return ServerSetupInstallResult(launcherPath: launcherURL.path, realmlistPath: realmlistURL.path)
    }

    static func startServer(serverPath: String) throws {
        let serverURL = try validatedServerDirectory(from: serverPath)
        try ensureComposeExists(at: serverURL)
        let result = try runCompose(in: serverURL, arguments: ["up", "-d"])
        guard result.exitCode == 0 else {
            let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerManagerError.commandFailed(output.isEmpty ? "Failed to start server containers." : output)
        }
    }

    static func stopServer(serverPath: String) throws {
        let serverURL = try validatedServerDirectory(from: serverPath)
        try ensureComposeExists(at: serverURL)
        let result = try runCompose(in: serverURL, arguments: ["down"])
        guard result.exitCode == 0 else {
            let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerManagerError.commandFailed(output.isEmpty ? "Failed to stop server containers." : output)
        }
    }

    static func runtimeState(serverPath: String) -> ServerRuntimeState {
        guard let serverURL = try? validatedServerDirectory(from: serverPath) else {
            return .notConfigured
        }
        guard (try? ensureComposeExists(at: serverURL)) != nil else {
            return .notConfigured
        }
        guard let result = try? runCompose(in: serverURL, arguments: ["ps", "--status", "running", "--services"]) else {
            return .error
        }
        guard result.exitCode == 0 else {
            return .error
        }

        let runningServices = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return runningServices.isEmpty ? .stopped : .running
    }

    // MARK: - Helpers

    private static func validatedServerDirectory(from path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServerManagerError.serverPathMissing }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ServerManagerError.serverPathNotFound(trimmed)
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    @discardableResult
    private static func validatedGameDirectory(from path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServerManagerError.gamePathMissing }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ServerManagerError.gamePathNotFound(trimmed)
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    private static func ensureComposeExists(at serverURL: URL) throws {
        let primary = serverURL.appendingPathComponent("docker-compose.yml")
        let secondary = serverURL.appendingPathComponent("docker-compose.yaml")
        guard FileManager.default.fileExists(atPath: primary.path) || FileManager.default.fileExists(atPath: secondary.path) else {
            throw ServerManagerError.composeFileMissing(serverURL.path)
        }
    }

    private static func runCompose(in directory: URL, arguments: [String]) throws -> ProcessRunResult {
        let dockerCompose = try ProcessRunner.run(
            executablePath: "/usr/bin/env",
            arguments: ["docker", "compose"] + arguments,
            currentDirectory: directory,
            timeout: 90
        )
        if dockerCompose.exitCode == 0 || !shouldFallbackToLegacyCompose(output: dockerCompose.combinedOutput) {
            return dockerCompose
        }

        return try ProcessRunner.run(
            executablePath: "/usr/bin/env",
            arguments: ["docker-compose"] + arguments,
            currentDirectory: directory,
            timeout: 90
        )
    }

    private static func shouldFallbackToLegacyCompose(output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("docker: 'compose' is not a docker command")
            || lowercased.contains("unknown shorthand flag")
            || lowercased.contains("no such command: compose")
    }

    private static func writeLauncherScript(serverDirectory: String, to launcherURL: URL) throws {
        let content = """
        #!/bin/bash
        # WoWSilicon — Vanilla server launcher

        set -euo pipefail

        cd "\(serverDirectory.replacingOccurrences(of: "\"", with: "\\\""))"
        docker compose up -d

        echo "Server started. Press ENTER to stop."
        read -r

        docker compose down
        echo "Server stopped."
        """
        try content.write(to: launcherURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: launcherURL.path)
    }

    private static func writeRealmlist(gamePath: String) throws -> URL {
        let gameURL = try validatedGameDirectory(from: gamePath)
        let rootRealmlist = gameURL.appendingPathComponent("realmlist.wtf")
        let localeRealmlist = gameURL.appendingPathComponent("Data/enUS/realmlist.wtf")

        let target: URL
        if FileManager.default.fileExists(atPath: localeRealmlist.path) {
            target = localeRealmlist
        } else if FileManager.default.fileExists(atPath: rootRealmlist.path) {
            target = rootRealmlist
        } else {
            target = rootRealmlist
        }

        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: target.path)
        try "set realmlist 127.0.0.1\n".write(to: target, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o444))], ofItemAtPath: target.path)
        return target
    }
}
