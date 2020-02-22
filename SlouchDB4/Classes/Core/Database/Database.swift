//
//  Database.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

// NOTE: This is a diff-based database. Requests to insert, update, remove must be done via ObjectDiffs provided
// to enqueue(). The changes do not take effect until mergeEnqueued() is called. This is to allow bulk processing
// of multiple diffs from external sources.
public class Database {
    public static let maxFetchCount: Int = 1000

    let objectHistoryTracker: ObjectHistoryTracker
    let objectStore: ObjectStore
    
    public init(objectStore: ObjectStore, objectHistoryTracker: ObjectHistoryTracker) {
        self.objectStore = objectStore
        self.objectHistoryTracker = objectHistoryTracker
    }
    
    public func save(to folderUrl: URL) {
        objectStore.save(to: folderUrl)
        
        let objectHistoryTrackerUrl = folderUrl.appendingPathComponent("object-history.json")
        objectHistoryTracker.save(to: objectHistoryTrackerUrl)
    }
    
    func enqueue(diffs: [ObjectDiff]) {
        objectHistoryTracker.enqueue(diffs: diffs)
    }
    
    func mergeEnqueued() {
        let mergeResult = objectHistoryTracker.process(objectStore: objectStore)
        objectStore.apply(mergeResult: mergeResult)
    }
    
    public func fetch(of type: String? = nil, limitCount: Int = Database.maxFetchCount, predicate: ((FetchedDatabaseObject) -> Bool)? = nil) -> FetchResult {
        return objectStore.fetch(of: type, limitCount: limitCount, predicate: predicate)
    }
    
    public func fetchMore(cursor: FetchCursor, limitCount: Int = Database.maxFetchCount) -> FetchResult {
        return objectStore.fetchMore(cursor: cursor, limitCount: limitCount)
    }
    
    public func count(of type: String, predicate: ((FetchedDatabaseObject) -> Bool)? = nil) -> ObjectCountResult {
        return objectStore.count(of: type, predicate: predicate)
    }
    
    public func fetch(identifier: String) -> DatabaseObject? {
        return objectStore.fetch(identifier: identifier)
    }
}
