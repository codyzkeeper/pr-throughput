import Foundation

/// A small, file-backed cache for the last verified GitHub snapshot.
///
/// Snapshots are derived data: GitHub remains the source of truth and the
/// cache can always be discarded and rebuilt. Keeping the cache in a single
/// atomic JSON file avoids requiring a database/macro plugin at app start and
/// makes schema changes fail safe (the next sync simply rebuilds the cache).
@MainActor
final class SnapshotStore {
    private struct Record: Codable {
        var payload: Data
        var savedAt: Date
    }

    private struct FileContents: Codable {
        var records: [String: Record]
    }

    private let inMemory: Bool
    private let fileURL: URL?
    private var records: [String: Record]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// `storageURL` is injectable for persistence tests. The app uses the
    /// default Application Support location.
    init(inMemory: Bool = false, storageURL: URL? = nil) throws {
        self.inMemory = inMemory
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601

        if inMemory {
            self.fileURL = nil
            self.records = [:]
            return
        }

        let resolvedURL: URL
        if let storageURL {
            resolvedURL = storageURL
        } else {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let appDirectory = directory.appendingPathComponent("PRThroughput", isDirectory: true)
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            resolvedURL = appDirectory.appendingPathComponent("snapshots.json", isDirectory: false)
        }

        try FileManager.default.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.fileURL = resolvedURL
        self.records = Self.readRecords(from: resolvedURL, decoder: decoder)
    }

    func load(accountID: String) throws -> AppSnapshot? {
        guard let record = records[accountID] else { return nil }
        do {
            return try decoder.decode(AppSnapshot.self, from: record.payload)
        } catch is DecodingError {
            // A schema change or partial old cache must never prevent a fresh
            // sync. Discard only this account and retain other accounts.
            records.removeValue(forKey: accountID)
            try persistIfNeeded()
            return nil
        }
    }

    func save(_ snapshot: AppSnapshot) throws {
        let payload = try encoder.encode(snapshot)
        records[snapshot.viewer.id] = Record(payload: payload, savedAt: Date())
        try persistIfNeeded()
    }

    func deleteAll() throws {
        records.removeAll(keepingCapacity: false)
        try persistIfNeeded()
    }

    private func persistIfNeeded() throws {
        guard !inMemory, let fileURL else { return }
        let data = try encoder.encode(FileContents(records: records))
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func readRecords(from url: URL, decoder: JSONDecoder) -> [String: Record] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let contents = try? decoder.decode(FileContents.self, from: data) else {
            // The cache is disposable. Leave a corrupt file in place for
            // diagnostics and let the next successful save replace it.
            return [:]
        }
        return contents.records
    }
}
