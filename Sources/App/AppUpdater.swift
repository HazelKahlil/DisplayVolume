import AppKit
import CryptoKit
import Foundation

/// Cryptographically verified native OTA updater for DisplayVolume.
/// Verifies Ed25519 manifest signatures, archive size & SHA-256, zip-slip/symlink safety,
/// strict nested codesign + Team ID continuity, same-volume atomic replacement, and safe relaunch.
@MainActor
final class AppUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(OTAManifestPayload)
        case downloading(Double)
        case verifying
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var autoCheckEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckEnabled, forKey: "AutoCheckOTAUpdates")
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    private var backgroundTimer: Timer?
    private var activeTask: Task<Void, Never>?
    private let redirectGuard = OTARedirectGuard()

    init() {
        let stored = UserDefaults.standard.object(forKey: "AutoCheckOTAUpdates") as? Bool
        self.autoCheckEnabled = stored ?? true
    }

    func startScheduledChecks() {
        backgroundTimer?.invalidate()
        let timer = Timer(timeInterval: 6 * 3600, target: self, selector: #selector(onScheduledTick), userInfo: nil, repeats: true)
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer

        if autoCheckEnabled {
            let lastCheck = UserDefaults.standard.double(forKey: "LastOTACheckTimestamp")
            if Date().timeIntervalSince1970 - lastCheck >= 24 * 3600 {
                checkForUpdates(userInitiated: false)
            }
        }
    }

    func stopScheduledChecks() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        activeTask?.cancel()
        activeTask = nil
    }

    @objc private func onScheduledTick() {
        guard autoCheckEnabled else { return }
        let lastCheck = UserDefaults.standard.double(forKey: "LastOTACheckTimestamp")
        if Date().timeIntervalSince1970 - lastCheck >= 24 * 3600 {
            checkForUpdates(userInitiated: false)
        }
    }

    private func setPhase(_ next: Phase) {
        if phase != next {
            phase = next
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        if case .downloading = phase { return }
        if case .verifying = phase { return }
        if case .installing = phase { return }

        activeTask?.cancel()
        if userInitiated {
            setPhase(.checking)
        }

        let curBuild = currentBuild
        let session = makeSecureSession()
        activeTask = Task { [weak self] in
            do {
                var request = URLRequest(url: OTAConfig.manifestURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 15
                let (data, response) = try await session.data(for: request)
                guard !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw OTAValidationError.signatureVerificationFailed(
                        L10n.text("无法拉取更新清单（网络或 GitHub 不可达）。", "Unable to fetch update manifest from GitHub.")
                    )
                }
                guard data.count <= 65_536 else {
                    throw OTAValidationError.invalidArchiveSize(Int64(data.count))
                }
                let signed = try JSONDecoder().decode(SignedOTAManifest.self, from: data)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "LastOTACheckTimestamp")

                do {
                    let verified = try OTAManifestVerifier.verify(signed, currentBuild: curBuild)
                    self?.setPhase(.available(verified))
                } catch OTAValidationError.notNewer {
                    self?.setPhase(userInitiated ? .upToDate : .idle)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if userInitiated {
                    self?.setPhase(.failed(error.localizedDescription))
                } else {
                    self?.setPhase(.idle)
                }
            }
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(OTAConfig.releasesPageURL)
    }

    func installAvailableUpdate(
        _ manifest: OTAManifestPayload,
        isAudioActivelyPlayingOnLockedDisplay: @escaping @MainActor () -> Bool
    ) {
        if isAudioActivelyPlayingOnLockedDisplay() {
            setPhase(.failed(L10n.text(
                "外接显示器正在播放声音，请先暂停播放再点击安装更新，避免切换期间短时恢复原声。",
                "Pause playback on the external display before installing update to prevent brief unattenuated audio."
            )))
            return
        }

        let targetURL = Bundle.main.bundleURL
        do {
            try OTAInstallPreflight.validateInstallTarget(bundleURL: targetURL)
        } catch {
            setPhase(.failed(error.localizedDescription))
            return
        }

        activeTask?.cancel()
        setPhase(.downloading(0.05))

        let ownIdentity = CodeSignInspector.currentProcessIdentity()
        let session = makeSecureSession()

        activeTask = Task { [weak self] in
            do {
                let stagedAppURL = try await Self.downloadAndVerifyUpdate(
                    manifest: manifest,
                    session: session,
                    ownIdentity: ownIdentity,
                    onProgress: { progress in
                        Task { @MainActor in self?.setPhase(.downloading(progress)) }
                    },
                    onVerifying: {
                        Task { @MainActor in self?.setPhase(.verifying) }
                    }
                )
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: stagedAppURL.deletingLastPathComponent().deletingLastPathComponent())
                    return
                }

                // Re-check playback, manifest expiry, and on-disk target build RIGHT before swap (prevents TOCTOU).
                if isAudioActivelyPlayingOnLockedDisplay() {
                    try? FileManager.default.removeItem(at: stagedAppURL.deletingLastPathComponent().deletingLastPathComponent())
                    throw OTAValidationError.signatureVerificationFailed(L10n.text(
                        "下载期间检测到外接显示器恢复播放，已中止自动换包以防爆音；请暂停播放后重试。",
                        "Playback resumed on external display during download. Pause playback and retry update."
                    ))
                }
                let iso = ISO8601DateFormatter()
                guard let expires = iso.date(from: manifest.expiresAt), expires > Date() else {
                    try? FileManager.default.removeItem(at: stagedAppURL.deletingLastPathComponent().deletingLastPathComponent())
                    throw OTAValidationError.expiredManifest(manifest.expiresAt)
                }

                self?.setPhase(.installing)
                try Self.atomicReplaceAndRelaunch(
                    stagedAppURL: stagedAppURL,
                    targetURL: targetURL,
                    expectedNewBuild: manifest.build
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.setPhase(.failed(error.localizedDescription))
            }
        }
    }

    private func makeSecureSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg, delegate: redirectGuard, delegateQueue: nil)
    }

    private nonisolated static func downloadAndVerifyUpdate(
        manifest: OTAManifestPayload,
        session: URLSession,
        ownIdentity: CodeSignInspector.SigningIdentity?,
        onProgress: @escaping @Sendable (Double) -> Void,
        onVerifying: @escaping @Sendable () -> Void
    ) async throws -> URL {
        guard let url = URL(string: manifest.downloadURL) else {
            throw OTAValidationError.untrustedDownloadURL(manifest.downloadURL)
        }

        // Private 0700 staging root in user caches directory
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayVolume-OTA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
        chmod(stageRoot.path, 0o700)

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (tempDownloadURL, response) = try await session.download(for: request)
            onProgress(0.85)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw OTAValidationError.signatureVerificationFailed("HTTP download failed")
            }

            let archiveURL = stageRoot.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tempDownloadURL, to: archiveURL)
            onProgress(1.0)
            onVerifying()

            // Verify exact size & SHA-256 from single open file handle to prevent check-vs-use drift.
            let handle = try FileHandle(forReadingFrom: archiveURL)
            defer { try? handle.close() }
            let archiveData = try handle.readToEnd() ?? Data()
            guard Int64(archiveData.count) == manifest.archiveSize else {
                throw OTAValidationError.invalidArchiveSize(Int64(archiveData.count))
            }
            let actualHash = OTAManifestVerifier.sha256Hex(of: archiveData)
            guard actualHash.caseInsensitiveCompare(manifest.archiveSHA256) == .orderedSame else {
                throw OTAValidationError.checksumMismatch
            }

            // Inspect archive entry paths BEFORE extracting (prevents zip-slip / escaping paths).
            let entries = try listZipEntries(archiveURL: archiveURL)
            try OTAArchiveSafety.validateEntryPaths(entries, expectedRoot: "DisplayVolume.app")

            let extractDir = stageRoot.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            let extractOK = runTool("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractDir.path])
            guard extractOK else {
                throw OTAValidationError.unsafeArchiveEntry("Failed to extract OTA archive")
            }

            let candidateApp = extractDir.appendingPathComponent("DisplayVolume.app", isDirectory: true)
            guard FileManager.default.fileExists(atPath: candidateApp.path) else {
                throw OTAValidationError.unsafeArchiveEntry("Missing DisplayVolume.app in extracted archive")
            }
            try OTAArchiveSafety.validateExtractedTree(at: candidateApp)

            // Verify outer UI app + nested Engine app code signatures, bundle IDs, build version, and Team ID continuity.
            try verifyBundleIdentityAndSignature(
                appURL: candidateApp,
                expectedBuild: manifest.build,
                ownIdentity: ownIdentity
            )

            return candidateApp
        } catch {
            try? FileManager.default.removeItem(at: stageRoot)
            throw error
        }
    }

    private nonisolated static func verifyBundleIdentityAndSignature(
        appURL: URL,
        expectedBuild: Int,
        ownIdentity: CodeSignInspector.SigningIdentity?
    ) throws {
        guard let outerSign = CodeSignInspector.inspectBundle(at: appURL, verifyStrict: true) else {
            throw OTAValidationError.signatureVerificationFailed("Outer DisplayVolume.app failed strict code-signature verification")
        }
        guard outerSign.identifier == VolumeIPC.suiteName else {
            throw OTAValidationError.wrongBundleID(outerSign.identifier)
        }
        let outerBuild = Int(Bundle(url: appURL)?.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
        guard outerBuild == expectedBuild else {
            throw OTAValidationError.signatureVerificationFailed("Extracted UI build (\(outerBuild)) does not match signed manifest (\(expectedBuild))")
        }

        let engineURL = appURL.appendingPathComponent("Contents/Helpers/DisplayVolumeEngine.app", isDirectory: true)
        guard let engineSign = CodeSignInspector.inspectBundle(at: engineURL, verifyStrict: true) else {
            throw OTAValidationError.signatureVerificationFailed("Nested DisplayVolumeEngine.app failed strict code-signature verification")
        }
        guard engineSign.identifier == VolumeIPC.engineBundleID else {
            throw OTAValidationError.wrongEngineBundleID(engineSign.identifier)
        }
        let engineBuild = Int(Bundle(url: engineURL)?.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
        guard engineBuild == expectedBuild else {
            throw OTAValidationError.signatureVerificationFailed("Nested Engine build (\(engineBuild)) does not match signed manifest (\(expectedBuild))")
        }

        // Enforce Team ID continuity whenever currently running app is signed with a real Apple Team ID.
        if let ownTeam = ownIdentity?.teamIdentifier, !ownTeam.isEmpty {
            guard outerSign.teamIdentifier == ownTeam, engineSign.teamIdentifier == ownTeam else {
                throw OTAValidationError.signatureVerificationFailed("Update Team Identifier mismatch (expected \(ownTeam))")
            }
        }
    }

    private nonisolated static func atomicReplaceAndRelaunch(
        stagedAppURL: URL,
        targetURL: URL,
        expectedNewBuild: Int
    ) throws {
        try InstallTransactionLock.withExclusiveLock {
            let parentDir = targetURL.deletingLastPathComponent()
            let sameVolumeStage = parentDir.appendingPathComponent(".DisplayVolume-ota-stage-\(UUID().uuidString).app", isDirectory: true)
            let backupName = ".DisplayVolume-ota-backup-\(UUID().uuidString).app"
            let backupURL = parentDir.appendingPathComponent(backupName, isDirectory: true)

            let fm = FileManager.default
            defer {
                try? fm.removeItem(at: stagedAppURL.deletingLastPathComponent().deletingLastPathComponent())
                try? fm.removeItem(at: sameVolumeStage)
            }

            // Re-check on-disk target build under exclusive install lock so an externally upgraded bundle is never downgraded.
            let onDiskPlist = targetURL.appendingPathComponent("Contents/Info.plist")
            if let plistData = try? Data(contentsOf: onDiskPlist),
               let dict = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
               let onDiskBuild = Int(dict["CFBundleVersion"] as? String ?? "0"),
               onDiskBuild >= expectedNewBuild {
                throw OTAValidationError.notNewer(currentBuild: onDiskBuild, candidateBuild: expectedNewBuild)
            }

            // Stage onto target's exact volume and KEEP backup via `.withoutDeletingBackupItem` for relaunch rollback.
            try fm.copyItem(at: stagedAppURL, to: sameVolumeStage)
            let replaced = try fm.replaceItemAt(
                targetURL,
                withItemAt: sameVolumeStage,
                backupItemName: backupName,
                options: [.withoutDeletingBackupItem]
            ) ?? targetURL

            // Wait for old UI exit, relaunch verified on-disk URL, and roll back to backup if relaunch fails.
            let myPID = getpid()
            let escapedPath = replaced.path.replacingOccurrences(of: "'", with: "'\\''")
            let escapedBackup = backupURL.path.replacingOccurrences(of: "'", with: "'\\''")
            let relaunchScript = """
            for _ in $(seq 1 40); do
              kill -0 \(myPID) 2>/dev/null || break
              sleep 0.1
            done
            if /usr/bin/open -n '\(escapedPath)'; then
              /bin/rm -rf '\(escapedBackup)'
            elif [ -d '\(escapedBackup)' ]; then
              /bin/rm -rf '\(escapedPath)'
              /bin/mv '\(escapedBackup)' '\(escapedPath)'
              /usr/bin/open -n '\(escapedPath)' || true
            fi
            """
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", relaunchScript]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
        }

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private nonisolated static func listZipEntries(archiveURL: URL) throws -> [String] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        task.arguments = ["-1", archiveURL.path]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw OTAValidationError.unsafeArchiveEntry("Failed to inspect zip entries")
        }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    private nonisolated static func runTool(_ path: String, _ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

private final class OTARedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme == "https",
              let host = url.host?.lowercased(),
              OTAConfig.allowedRedirectHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Cross-process advisory flock mutex protecting Engine install, OTA replacement, and uninstall transactions.
enum InstallTransactionLock {
    static func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: VolumeIPC.directory, withIntermediateDirectories: true)
        let lockPath = VolumeIPC.installLockFile.path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid() else {
            throw OTAValidationError.signatureVerificationFailed("Install lock file ownership/type check failed")
        }
        guard flock(fd, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EAGAIN)
        }
        return try body()
    }
}
