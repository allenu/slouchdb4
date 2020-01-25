//
//  Database.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation
import BTree

public enum ObjectCountResult {
    case exactly(Int)
    case moreThan(Int)
}

public struct FetchCursor {
    // TODO: whichIndex
    // - identifier, date created, date last modified ?
    public let nextObjectOffset: Int
    public let noMoreResults: Bool
    let predicate: ((DatabaseObject) -> Bool)?
}

public struct FetchResult {
    public let results: [DatabaseObject]
    public let cursor: FetchCursor
}

// TODO: Maybe we want to fetch both !? Sort of neat to get a full history
// of changes to process.
struct DatabaseObjectAndDiffs {
    let object: DatabaseObject
    let diffs: [ObjectDiff]
}

// NOTE: This is a diff-based database. Requests to insert, update, remove must be done via ObjectDiffs provided
// to enqueue(). The changes do not take effect until mergeEnqueued() is called. This is to allow bulk processing
// of multiple diffs from external sources.
class Database {
    public static let maxFetchCount: Int = 1000
    
    // WIP: In-mem sorted list of all item indices
    public typealias SortedIdentifiers = SortedSet<String>
    var sortedIdentifiers: SortedIdentifiers = SortedIdentifiers()

    let objectHistoryTracker: ObjectHistoryTracker = ObjectHistoryTracker()
    let objectCache: ObjectCache = ObjectCache()
    
    func enqueue(diffs: [ObjectDiff]) {
        objectHistoryTracker.enqueue(diffs: diffs)
    }
    
    func mergeEnqueued() {
        let mergeResult = objectHistoryTracker.process(objectCache: objectCache)
        if mergeResult.totalChanges > 0 {
            
            // Apply the changes
            mergeResult.insertedObjects.forEach { identifier, object in
                objectCache.insert(identifier: identifier, object: object)
                
                sortedIdentifiers.insert(identifier)
            }

            mergeResult.updatedObjects.forEach { identifier, object in
                objectCache.replace(identifier: identifier, object: object)
                
                assert(sortedIdentifiers.contains(identifier))
            }
            
            mergeResult.removedObjects.forEach { identifier in
                objectCache.remove(identifier: identifier)
                sortedIdentifiers.remove(identifier)
            }
        }
    }
    
    public func fetch(of type: String, limitCount: Int = Database.maxFetchCount, predicate: ((DatabaseObject) -> Bool)? = nil) -> FetchResult {
        let cursor = FetchCursor(nextObjectOffset: 0, noMoreResults: false, predicate: predicate)
        return fetchMore(cursor: cursor, limitCount: limitCount)
    }
    
    public func fetchMore(cursor: FetchCursor, limitCount: Int = Database.maxFetchCount) -> FetchResult {
        // If we've gone past the index by now, stop
        var currentPosition = cursor.nextObjectOffset
        var collectedItems: [DatabaseObject] = []
        while currentPosition < sortedIdentifiers.count && collectedItems.count < limitCount {
            let nextIdentifier = sortedIdentifiers[currentPosition]
            
            let shouldIncludeObject: Bool
            if let objectState = self.fetch(identifier: nextIdentifier) {
                if let predicate = cursor.predicate {
                    shouldIncludeObject = predicate(objectState)
                } else {
                    shouldIncludeObject = true
                }
                if shouldIncludeObject {
                    collectedItems.append(objectState)
                }
            } else {
                assertionFailure("Cache mismatch. Identifier shows up in sortedIdentifiers but not in cache")
            }
            
            currentPosition = currentPosition + 1
        }
        
        let noMoreResults = (currentPosition == sortedIdentifiers.count)
        
        let cursor = FetchCursor(nextObjectOffset: currentPosition, noMoreResults: noMoreResults, predicate: cursor.predicate)
        let fetchResult = FetchResult(results: collectedItems, cursor: cursor)
        return fetchResult
    }
    
    public func count(of type: String, predicate: ((DatabaseObject) -> Bool)? = nil) -> ObjectCountResult {
        let fetchResult = fetch(of: type, predicate: predicate)
        
        if fetchResult.results.count == 0 {
            return ObjectCountResult.exactly(0)
        } else if fetchResult.cursor.noMoreResults {
            return ObjectCountResult.exactly(fetchResult.results.count)
        } else {
            return ObjectCountResult.moreThan(fetchResult.results.count)
        }
    }
    
    public func fetch(identifier: String) -> DatabaseObject? {
        return objectCache.fetch(identifier: identifier)
    }
}
