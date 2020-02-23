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
    var localIdentifier: String { get }
    
    func addToLocalJournal(diff: ObjectDiff)
    func fetchLatestDiffs(completion: @escaping (FetchJournalDiffsResponse, CallbackWhenDiffsMerged?) -> Void)
    
    func save(to folderUrl: URL)
}

public enum SessionSyncResponse {
    case success
    case failure
}

public protocol SessionDelegate: class {
    func session(_ session: Session, didRequestMerge mergeResult: MergeResult)
}

public protocol SessionDataSource: class {
    func session(_ session: Session, objectFor identifier: String) -> DatabaseObject?
}

// Session does the following:
// - stores diffs on local Insert, Update, Delete requests into local journal
// - coordinates "merging" remote changes into local object history
// -
//
public class Session {
    let journalManager: JournalManaging
    let objectHistoryTracker: ObjectHistoryTracker
    
    public weak var delegate: SessionDelegate?
    public weak var dataSource: SessionDataSource?

    public var localIdentifier: String {
        return journalManager.localIdentifier
    }
    
    public init(journalManager: JournalManaging, objectHistoryStore: ObjectHistoryStoring) {
        self.journalManager = journalManager
        self.objectHistoryTracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
    }
    
    public static func create(from folderUrl: URL, with remoteFileStore: RemoteFileStoring) -> Session? {
        if let objectHistoryStore = InMemObjectHistoryStore.create(from: folderUrl),
            let journalManager = JournalManager.create(from: folderUrl, with: remoteFileStore) {
            return Session(journalManager: journalManager, objectHistoryStore: objectHistoryStore)
        }
        
        return nil
    }
    
    public func save(to folderUrl: URL) {
        objectHistoryTracker.save(to: folderUrl)
        journalManager.save(to: folderUrl)
    }
    
    func enqueue(diffs: [ObjectDiff]) {
        objectHistoryTracker.enqueue(diffs: diffs)
    }
    
    func mergeEnqueued() {
        let mergeResult = objectHistoryTracker.process(objectProvider: self)
        delegate?.session(self, didRequestMerge: mergeResult)
    }
    
    // Local database changes
    public func insert(identifier: String, object: DatabaseObject) {
        let now = Date()
        let diff = ObjectDiff.insert(identifier: identifier, timestamp: now, object: object)
        journalManager.addToLocalJournal(diff: diff)
        enqueue(diffs: [diff])
        mergeEnqueued()
    }
    
    public func remove(identifier: String) {
        let now = Date()
        let diff = ObjectDiff.remove(identifier: identifier, timestamp: now)
        journalManager.addToLocalJournal(diff: diff)
        enqueue(diffs: [diff])
        mergeEnqueued()
    }
    
    public func update(identifier: String, updatedProperties: [String : JSONValue]) {
        let now = Date()
        let diff = ObjectDiff.update(identifier: identifier, timestamp: now, properties: updatedProperties)
        journalManager.addToLocalJournal(diff: diff)
        enqueue(diffs: [diff])
        mergeEnqueued()
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

                        // Process the partial results and let JournalManager that we've
                        // saved them.
                        strongSelf.mergeEnqueued()
                        callbackWhenDiffsMerged?(true)

                        // Tell client of Session that we have partial results ready.
                        partialResults(percent)

                        // Still have more results, so run sync() again
                        strongSelf.sync(completion: completion, partialResults: partialResults)
                    }
                    
                case .results(let diffs):
                    processDiffs(diffs)
                    DispatchQueue.main.async {
                        strongSelf.mergeEnqueued()
                        callbackWhenDiffsMerged?(true)
                        
                        completion(.success)
                    }
                }

            case .failure:
                DispatchQueue.main.async {
                    callbackWhenDiffsMerged?(false)
                    completion(.failure)
                }
            }
        })
    }
}

extension Session: ObjectProvider {
    public func object(for identifier: String) -> DatabaseObject? {
        return dataSource?.session(self, objectFor: identifier)
    }
}
