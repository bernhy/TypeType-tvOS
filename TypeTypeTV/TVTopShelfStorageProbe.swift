#if DEBUG
import Foundation
import TVServices

/// One-shot on-device diagnosis. The ordinary Top Shelf writer and reader
/// keep their existing paths; probes only create and remove their own files.
/// All file operations run off the main actor so navigation stays untouched.
enum TVTopShelfStorageProbe {
    @MainActor private static var started = false
    @MainActor private static var challenge: String?
    @MainActor private static var lastAckStatus: String?

    @MainActor
    static func startOnce() {
        // Never run file-system probes in network-free screenshot/UI fixtures.
        guard !started,
              !ProcessInfo.processInfo.arguments.contains("-TypeTypeTVPreview")
        else { return }
        started = true
        let marker = UUID().uuidString
        challenge = marker
        Task.detached(priority: .utility) {
            run(marker: marker)
        }
    }

    @MainActor
    static func reportExtensionAcknowledgement() {
        guard let marker = challenge,
              let groupID = Bundle.main.object(
                  forInfoDictionaryKey: "TopShelfAppGroupID"
              ) as? String else { return }
        let received = UserDefaults(suiteName: groupID)?
            .string(forKey: TVTopShelfSnapshotStore.debugProbeAckKey)
        let status = received == marker ? "MATCH" : "NOT_YET_RECEIVED"
        guard lastAckStatus != status else { return }
        lastAckStatus = status
        NSLog("TypeType TOPSHELF PROBE extension acknowledgement=%@", status)
    }

    private static func run(marker: String) {
        let manager = FileManager.default
        let local = manager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        probeDirectory("app-support", at: local)

        // Use the exact container URL already used by the publisher.
        let groupContainer = TVTopShelfSnapshotStore.container()
        probeDirectory("group-root", at: groupContainer)
        let sharedSupport = groupContainer?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        probeDirectory("group-library-support", at: sharedSupport)

        guard let groupID = Bundle.main.object(
            forInfoDictionaryKey: "TopShelfAppGroupID"
        ) as? String, groupID.hasPrefix("group.") else {
            NSLog("TypeType TOPSHELF PROBE suite=NO_GROUP_ID")
            return
        }
        guard let defaults = UserDefaults(suiteName: groupID) else {
            NSLog("TypeType TOPSHELF PROBE suite=UNAVAILABLE")
            return
        }

        defaults.removeObject(forKey: TVTopShelfSnapshotStore.debugProbeAckKey)
        defaults.set(marker, forKey: TVTopShelfSnapshotStore.debugProbeChallengeKey)
        // A single explicit flush is intentional for this cross-process test;
        // it is not part of the regular Top Shelf or UI hot path.
        let flushed = defaults.synchronize()
        let localRead = defaults.string(
            forKey: TVTopShelfSnapshotStore.debugProbeChallengeKey
        ) == marker
        NSLog("TypeType TOPSHELF PROBE suite localRead=%@ flush=%@ marker=%@",
              localRead ? "PASS" : "FAIL",
              flushed ? "PASS" : "FAIL", String(marker.prefix(8)))
        // Make the extension load if tvOS permits it; the extension must
        // independently read the marker and acknowledge it in the same suite.
        Task { @MainActor in
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
    }

    private static func probeDirectory(_ label: String, at directory: URL?) {
        guard let directory else {
            NSLog("TypeType TOPSHELF PROBE %@ container=UNAVAILABLE", label)
            return
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logError(label: label, operation: "createDirectory", error: error)
            return
        }
        NSLog("TypeType TOPSHELF PROBE %@ createDirectory=PASS", label)

        let data = Data("topshelf-probe".utf8)
        let methods: [(String, Data.WritingOptions)] = [
            ("direct", []), ("atomic", .atomic)
        ]
        for (method, options) in methods {
            let url = directory.appendingPathComponent(
                ".typetype-probe-" + UUID().uuidString
            )
            defer { try? fm.removeItem(at: url) }
            do {
                try data.write(to: url, options: options)
            } catch {
                logError(label: label, operation: method + "-write", error: error)
                continue
            }
            do {
                let actual = try Data(contentsOf: url)
                NSLog("TypeType TOPSHELF PROBE %@ %@ write=PASS read=%@",
                      label, method, actual == data ? "PASS" : "MISMATCH")
            } catch {
                logError(label: label, operation: method + "-read", error: error)
            }
        }
    }

    private static func logError(label: String, operation: String, error: Error) {
        let nsError = error as NSError
        // No filesystem paths, server addresses, account names or group IDs.
        NSLog("TypeType TOPSHELF PROBE %@ %@ failed domain=%@ code=%ld",
              label, operation, nsError.domain, nsError.code)
    }
}
#endif
