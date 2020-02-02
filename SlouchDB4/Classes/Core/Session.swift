//
//  Session.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public enum SyncFilesFailureReason {
    case pushFailed
    case fetchRemoteVersionsFailed
    case fetchRemoteFilesFailed
}

public enum SyncFilesResponse {
    case success(updatedFiles: [String])
    case failure(reason: SyncFilesFailureReason)
}

public enum FetchJournalSuccessType {
    case partialResults(diffs: [ObjectDiff], percent: Double)
    case results(diffs: [ObjectDiff])
}

public enum FetchJournalDiffsResponse {
    case success(type: FetchJournalSuccessType)
    // case successNoChanges
    case failure
}

// CallbackWhenDiffsMerged is passed in to ensure that when the caller gets the diffs it tells us
// it is done so that we can save the updated journal states to file. This is to ensure that if
// anything happens during the merge. On failure, the callback is nil since we do not care.
public typealias CallbackWhenDiffsMerged = (Bool) -> Void

public protocol JournalManaging {
    func addToLocalJournal(diff: ObjectDiff)
    func fetchLatestDiffs(completion: @escaping (FetchJournalDiffsResponse, CallbackWhenDiffsMerged?) -> Void)
    
    func save(to folderUrl: URL)
}

public enum SessionSyncResponse {
    case success
    case failure
}

// Session provides a nice wrapper around the diff-based Database. It also
// stores local changes to its own journal and keeps track of any external
// journals.
public class Session {
    let database: Database
    let journalManager: JournalManaging
    
    public init(database: Database, journalManager: JournalManaging) {
        self.journalManager = journalManager
        self.database = database
    }
    
    public static func create(from folderUrl: URL) -> Session? {
        let databaseUrl = folderUrl.appendingPathComponent("database")
        let journalUrl = folderUrl.appendingPathComponent("journals")

        // TODO: Move to Database() somehow ... but it exposes details of how
        let objectCacheUrl = databaseUrl.appendingPathComponent("object-cache.json")
        let objectHistoryTrackerUrl = databaseUrl.appendingPathComponent("object-history.json")

        
        if let objectCache = InMemObjectCache.create(from: objectCacheUrl),
            let objectHistoryTracker = ObjectHistoryTracker.create(from: objectHistoryTrackerUrl) {

            let sortedIdentifiersUrl = databaseUrl.appendingPathComponent("sorted-identifiers.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let data = try? Data(contentsOf: sortedIdentifiersUrl),
                let sortedIdentifiers = try? decoder.decode([String].self, from: data) {
                let database = Database(objectCache: objectCache, objectHistoryTracker: objectHistoryTracker, sortedIdentifiers: sortedIdentifiers)
                
                if let journalManager = JournalManager.create(from: journalUrl) {
                    return Session(database: database, journalManager: journalManager)
                }
            }
        }
        
        return nil
    }
    
    public func save(to folderUrl: URL) {
        let databaseUrl = folderUrl.appendingPathComponent("database")
        // Create database folder, if needed
        do {
            try FileManager.default.createDirectory(at: databaseUrl, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Error creating dir \(databaseUrl)")
        }
        database.save(to: databaseUrl)

        let journalUrl = folderUrl.appendingPathComponent("journals")
        do {
            try FileManager.default.createDirectory(at: journalUrl, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Error creating dir \(journalUrl)")
        }
        journalManager.save(to: journalUrl)
    }
    
    func enqueue(diffs: [ObjectDiff]) {
        database.enqueue(diffs: diffs)
    }
    
    func mergeEnqueued() {
        database.mergeEnqueued()
    }
    
    // Local database changes
    public func insert(identifier: String, object: DatabaseObject) {
        let now = Date()
        let diff = ObjectDiff.insert(identifier: identifier, timestamp: now, object: object)
        journalManager.addToLocalJournal(diff: diff)
        enqueue(diffs: [diff])
    }
    
    public func remove(identifier: String) {
        let now = Date()
        let diff = ObjectDiff.remove(identifier: identifier, timestamp: now)
        journalManager.addToLocalJournal(diff: diff)
        enqueue(diffs: [diff])
    }
    
    public func update(identifier: String, updatedProperties: [String : JSONValue]) {
        let now = Date()
        let diff = ObjectDiff.update(identifier: identifier, timestamp: now, properties: updatedProperties)
        journalManager.addToLocalJournal(diff: diff)
        enqueue(diffs: [diff])
    }
    
    public func sync(completion: @escaping (SessionSyncResponse) -> Void, partialResults: @escaping (Double) -> Void) {
        journalManager.fetchLatestDiffs(completion: { [weak self] response, callbackWhenDiffsMerged in
            guard let strongSelf = self else { return }
            
            switch response {
            case .success(let type):
                // TODO: Do processing in background thread
                
                let processDiffs: ([ObjectDiff]) -> Void = { diffs in
                    strongSelf.enqueue(diffs: diffs)
                }
                
                switch type {
                case .partialResults(let diffs, let percent):
                    processDiffs(diffs)
                    DispatchQueue.main.async {
                        partialResults(percent)
                        
                        // Still have more results, so run sync() again
                        strongSelf.sync(completion: completion, partialResults: partialResults)

                        callbackWhenDiffsMerged?(true)
                    }
                    
                case .results(let diffs):
                    processDiffs(diffs)
                    DispatchQueue.main.async {
                        completion(.success)
                        
                        callbackWhenDiffsMerged?(true)
                    }
                }

            case .failure:
                DispatchQueue.main.async {
                    completion(.failure)
                    
                    callbackWhenDiffsMerged?(false)
                }
            }
        })
    }
}
