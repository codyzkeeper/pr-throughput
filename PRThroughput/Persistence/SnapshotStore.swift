import Foundation
import SwiftData

@Model
final class StoredSnapshot {
    @Attribute(.unique) var accountID: String
    var payload: Data
    var savedAt: Date

    init(accountID: String, payload: Data, savedAt: Date = Date()) {
        self.accountID = accountID
        self.payload = payload
        self.savedAt = savedAt
    }
}

@MainActor
final class SnapshotStore {
    private let container: ModelContainer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: StoredSnapshot.self, configurations: configuration)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(accountID: String) throws -> AppSnapshot? {
        let context = ModelContext(container)
        let key = accountID
        var descriptor = FetchDescriptor<StoredSnapshot>(predicate: #Predicate { $0.accountID == key })
        descriptor.fetchLimit = 1
        guard let stored = try context.fetch(descriptor).first else { return nil }
        do {
            return try decoder.decode(AppSnapshot.self, from: stored.payload)
        } catch is DecodingError {
            // The cache is derived entirely from GitHub. Discard an obsolete or
            // corrupt payload so a schema change cannot prevent reconnection.
            context.delete(stored)
            try context.save()
            return nil
        }
    }

    func save(_ snapshot: AppSnapshot) throws {
        let context = ModelContext(container)
        let key = snapshot.viewer.id
        let payload = try encoder.encode(snapshot)
        var descriptor = FetchDescriptor<StoredSnapshot>(predicate: #Predicate { $0.accountID == key })
        descriptor.fetchLimit = 1
        if let stored = try context.fetch(descriptor).first {
            stored.payload = payload
            stored.savedAt = Date()
        } else {
            context.insert(StoredSnapshot(accountID: key, payload: payload))
        }
        try context.save()
    }

    func deleteAll() throws {
        let context = ModelContext(container)
        try context.delete(model: StoredSnapshot.self)
        try context.save()
    }
}
