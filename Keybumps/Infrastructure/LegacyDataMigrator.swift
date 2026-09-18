import AppKit
import Foundation

enum AppRuntimeEnvironment {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

struct LegacyInstallationDetector {
    private let fileManager: FileManager
    private let paths: ProductPaths
    private let defaults: UserDefaults
    private let defaultsDomainName: String
    private let applicationURLs: [URL]

    init(
        fileManager: FileManager = .default,
        paths: ProductPaths? = nil,
        defaults: UserDefaults? = nil,
        defaultsDomainName: String = ProductIdentity.legacyBundleIdentifier,
        applicationURLs: [URL]? = nil
    ) {
        self.fileManager = fileManager
        self.paths = paths ?? .legacySuperMac(fileManager: fileManager)
        self.defaults = defaults
            ?? UserDefaults(suiteName: defaultsDomainName)
            ?? .standard
        self.defaultsDomainName = defaultsDomainName
        self.applicationURLs = applicationURLs ?? [
            URL(fileURLWithPath: "/Applications/SuperMac.app", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/SuperMac.app", isDirectory: true)
        ]
    }

    var isPresent: Bool {
        applicationURLs.contains { fileManager.fileExists(atPath: $0.path) }
            || fileManager.fileExists(atPath: paths.applicationSupport.path)
            || fileManager.fileExists(atPath: paths.recordings.path)
            || !(defaults.persistentDomain(forName: defaultsDomainName)?.isEmpty ?? true)
    }
}

enum LegacyMigrationError: Error, Equatable {
    case legacyAppRunning
}

struct LegacyAppProcessDetector {
    private let isRunningHandler: (pid_t) -> Bool

    init(isRunningHandler: @escaping (pid_t) -> Bool = { currentProcessIdentifier in
        NSRunningApplication.runningApplications(withBundleIdentifier: ProductIdentity.legacyBundleIdentifier).contains {
            $0.processIdentifier != currentProcessIdentifier && !$0.isTerminated
        }
    }) {
        self.isRunningHandler = isRunningHandler
    }

    func isLegacySuperMacRunning(currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        isRunningHandler(currentProcessIdentifier)
    }
}

struct LegacyDataMigrator {
    static let currentVersion = 1
    static let markerKey = "legacySuperMacMigrationVersion"

    private static let preferenceKeys = [
        "selectedNotificationChannels",
        "showInDockAndSwitcher",
        "enabledCapabilities",
        "dictationLanguage",
        "dictationDurationLimit",
        "capabilityShortcuts",
        "windowShortcuts"
    ]

    private let fileManager: FileManager
    private let legacyPaths: ProductPaths
    private let destinationPaths: ProductPaths
    private let legacyDefaults: UserDefaults
    private let destinationDefaults: UserDefaults

    init(
        fileManager: FileManager = .default,
        legacyPaths: ProductPaths? = nil,
        destinationPaths: ProductPaths? = nil,
        legacyDefaults: UserDefaults? = nil,
        destinationDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.legacyPaths = legacyPaths ?? .legacySuperMac(fileManager: fileManager)
        self.destinationPaths = destinationPaths ?? .keybumps(fileManager: fileManager)
        self.legacyDefaults = legacyDefaults
            ?? UserDefaults(suiteName: ProductIdentity.legacyBundleIdentifier)
            ?? .standard
        self.destinationDefaults = destinationDefaults
    }

    func migrateIfNeeded() throws {
        guard destinationDefaults.integer(forKey: Self.markerKey) < Self.currentVersion else { return }

        try fileManager.createDirectory(
            at: destinationPaths.applicationSupport,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destinationPaths.recordings,
            withIntermediateDirectories: true
        )

        try migrateApplicationSupport()
        try mergeDirectory(
            from: legacyPaths.recordings,
            to: destinationPaths.recordings,
            mergeExistingDirectories: false
        )
        migratePreferences()
        destinationDefaults.set(Self.currentVersion, forKey: Self.markerKey)
    }

    private func migrateApplicationSupport() throws {
        let fileNames = [
            "coaching-events.json",
            "recent-items.json",
            "application-usage.json",
            "last-dictation.txt"
        ]
        for fileName in fileNames {
            try mergeFile(
                from: legacyPaths.applicationSupport.appendingPathComponent(fileName),
                to: destinationPaths.applicationSupport.appendingPathComponent(fileName)
            )
        }

        try mergeDirectory(
            from: legacyPaths.applicationSupport.appendingPathComponent("clipboard-media", isDirectory: true),
            to: destinationPaths.applicationSupport.appendingPathComponent("clipboard-media", isDirectory: true),
            mergeExistingDirectories: true
        )
        try migrateClipboardIndex()
    }

    private func migrateClipboardIndex() throws {
        let source = legacyPaths.applicationSupport.appendingPathComponent("clipboard-history.json")
        let destination = destinationPaths.applicationSupport.appendingPathComponent("clipboard-history.json")
        guard fileManager.fileExists(atPath: source.path) else { return }

        let sourceObject = try JSONSerialization.jsonObject(with: Data(contentsOf: source))
        guard var sourceRecords = sourceObject as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        sourceRecords = sourceRecords.compactMap { record in
            var migrated = record
            if let mediaPath = migrated["mediaPath"] as? String {
                guard let rebasedPath = rebasedClipboardMediaPath(mediaPath),
                      fileManager.fileExists(atPath: rebasedPath) else { return nil }
                migrated["mediaPath"] = rebasedPath
            }
            return migrated
        }

        let destinationRecords: [[String: Any]]
        if fileManager.fileExists(atPath: destination.path) {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: destination))
            guard let records = object as? [[String: Any]] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            destinationRecords = records
        } else {
            destinationRecords = []
        }

        var identifiers = Set(destinationRecords.compactMap { $0["id"] as? String })
        let missingRecords = sourceRecords.filter { record in
            guard let identifier = record["id"] as? String else { return false }
            return identifiers.insert(identifier).inserted
        }
        guard !missingRecords.isEmpty || !fileManager.fileExists(atPath: destination.path) else { return }
        let merged = destinationRecords + missingRecords
        try writeJSONObject(merged, to: destination)
    }

    private func rebasedClipboardMediaPath(_ path: String) -> String? {
        let legacyMediaRoot = legacyPaths.applicationSupport
            .appendingPathComponent("clipboard-media", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard standardizedPath.hasPrefix(legacyMediaRoot + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        let legacyRoot = legacyPaths.applicationSupport.standardizedFileURL.path
        let suffix = String(standardizedPath.dropFirst(legacyRoot.count))
        return destinationPaths.applicationSupport.standardizedFileURL.path + suffix
    }

    private func mergeFile(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
            return
        }

        guard source.pathExtension == "json" else { return }
        let sourceObject = try JSONSerialization.jsonObject(with: Data(contentsOf: source))
        let destinationObject = try JSONSerialization.jsonObject(with: Data(contentsOf: destination))
        if let sourceRecords = sourceObject as? [[String: Any]],
           let destinationRecords = destinationObject as? [[String: Any]] {
            let merged = mergeRecordArrays(destinationRecords: destinationRecords, sourceRecords: sourceRecords)
            if merged.count != destinationRecords.count { try writeJSONObject(merged, to: destination) }
        } else if let sourceRecords = sourceObject as? [String: Any],
                  let destinationRecords = destinationObject as? [String: Any] {
            var merged = destinationRecords
            for (key, value) in sourceRecords where merged[key] == nil { merged[key] = value }
            if merged.count != destinationRecords.count { try writeJSONObject(merged, to: destination) }
        }
    }

    private func mergeRecordArrays(
        destinationRecords: [[String: Any]],
        sourceRecords: [[String: Any]]
    ) -> [[String: Any]] {
        var merged = destinationRecords
        var identities = Set(destinationRecords.compactMap(recordIdentity))
        for record in sourceRecords {
            guard let identity = recordIdentity(record), identities.insert(identity).inserted else { continue }
            merged.append(record)
        }
        return merged
    }

    private func recordIdentity(_ record: [String: Any]) -> String? {
        if let id = record["id"] as? String { return "id:\(id)" }
        if let result = record["result"] as? [String: Any], let url = result["url"] as? String {
            return "url:\(url)"
        }
        return nil
    }

    private func mergeDirectory(
        from source: URL,
        to destination: URL,
        mergeExistingDirectories: Bool
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let destinationItem = destination.appendingPathComponent(item.lastPathComponent)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                if fileManager.fileExists(atPath: destinationItem.path), !mergeExistingDirectories {
                    continue
                }
                try mergeDirectory(
                    from: item,
                    to: destinationItem,
                    mergeExistingDirectories: mergeExistingDirectories
                )
            } else if !fileManager.fileExists(atPath: destinationItem.path) {
                try fileManager.copyItem(at: item, to: destinationItem)
            }
        }
    }

    private func migratePreferences() {
        for key in Self.preferenceKeys where destinationDefaults.object(forKey: key) == nil {
            guard let value = legacyDefaults.object(forKey: key) else { continue }
            destinationDefaults.set(translatingLegacyIdentifiers(in: value), forKey: key)
        }
    }

    private func translatingLegacyIdentifiers(in value: Any) -> Any {
        if let string = value as? String {
            return switch string {
            case "shortcutCoaching": "keyboardShortcutter"
            case "keyBumpsHistory": "keyboardShortcutterHistory"
            default: string
            }
        }
        if let array = value as? [Any] {
            return array.map(translatingLegacyIdentifiers)
        }
        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map {
                (translatingLegacyIdentifiers(in: $0.key) as? String ?? $0.key,
                 translatingLegacyIdentifiers(in: $0.value))
            })
        }
        if let data = value as? Data,
           let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object),
           let translated = try? JSONSerialization.data(
               withJSONObject: translatingLegacyIdentifiers(in: object),
               options: [.sortedKeys]
           ) {
            return translated
        }
        return value
    }

    private func writeJSONObject(_ object: Any, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

struct KeybumpsStartupPreparation {
    let processDetector: LegacyAppProcessDetector
    let migrator: LegacyDataMigrator

    init(
        processDetector: LegacyAppProcessDetector = LegacyAppProcessDetector(),
        migrator: LegacyDataMigrator = LegacyDataMigrator()
    ) {
        self.processDetector = processDetector
        self.migrator = migrator
    }

    func prepare() throws {
        guard !processDetector.isLegacySuperMacRunning() else {
            throw LegacyMigrationError.legacyAppRunning
        }
        try migrator.migrateIfNeeded()
    }
}

@MainActor
final class LegacyAppCoexistenceMonitor {
    var onLegacyAppDetected: (() -> Void)?
    private let workspace: NSWorkspace
    private let processDetector: LegacyAppProcessDetector
    private var launchObserver: NSObjectProtocol?

    init(
        workspace: NSWorkspace = .shared,
        processDetector: LegacyAppProcessDetector = LegacyAppProcessDetector()
    ) {
        self.workspace = workspace
        self.processDetector = processDetector
    }

    func start() {
        guard launchObserver == nil else { return }
        launchObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.bundleIdentifier == ProductIdentity.legacyBundleIdentifier else { return }
            Task { @MainActor in self?.onLegacyAppDetected?() }
        }
        if processDetector.isLegacySuperMacRunning() {
            onLegacyAppDetected?()
        }
    }

    deinit {
        if let launchObserver {
            workspace.notificationCenter.removeObserver(launchObserver)
        }
    }
}
