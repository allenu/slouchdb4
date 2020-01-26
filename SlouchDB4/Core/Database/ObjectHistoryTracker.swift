//
//  ObjectHistoryTracker.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation
import BTree

enum ObjectHistoryProcessingState {
    case fastForward(nextDiffIndex: Int)
    case replay
}

typealias ObjectHistory =  [ObjectDiff]

class ObjectHistoryState {
    var processingState: ObjectHistoryProcessingState
    var diffs: [ObjectDiff]
    
    init(processingState: ObjectHistoryProcessingState,
         diffs: [ObjectDiff] = []) {
        self.processingState = processingState
        self.diffs = diffs
    }
}

struct MergeResult {
    let insertedObjects: [String : DatabaseObject]
    let removedObjects: [String]
    let updatedObjects: [String : DatabaseObject]
    
    var totalChanges: Int {
        return insertedObjects.count + removedObjects.count + updatedObjects.count
    }
}

public class ObjectHistoryTracker {
    var histories: [String : ObjectHistoryState] = [:]
    
    // Cache which objects need update so that process() is faster.
    var pendingUpdates: Set<String> = Set<String>()
    
    // This queues up the diffs provided and updates the histories of each object.
    public func enqueue(diffs: [ObjectDiff]) {
        diffs.forEach { diff in
            if let objectHistoryState = histories[diff.identifier] {
                let originalDiffCount = objectHistoryState.diffs.count

                if let lastDiff = objectHistoryState.diffs.last {
                    if diff.timestamp > lastDiff.timestamp {
                        // See if this diff's timestamp is newer than the last one, we can
                        // just append.
                        // processingState is whatever it was
                        objectHistoryState.diffs.append(diff)
                    } else if diff.timestamp == lastDiff.timestamp {
                        // Timestamps are equal, so see if it's the same diff we are inserting
                        // again...
                        if diff == lastDiff {
                            // Same diff. We already know about it, so do nothing.
                        } else {
                            // New diff! Append it. processingState is whatever it was
                            objectHistoryState.diffs.append(diff)
                        }
                    } else {
                        // This diff may change history. Find where to insert it.
                        let firstDiffNewerIndex = objectHistoryState.diffs.firstIndex(where: { $0.timestamp >= diff.timestamp })!
                        
                        // See if this is the same diff as the one we're inserting
                        let firstDiffNewer = objectHistoryState.diffs[firstDiffNewerIndex]
                        if firstDiffNewer == diff {
                            // Already know about it, so don't insert.
                        } else {
                            // Insert diff before that one
                            objectHistoryState.diffs.insert(diff, at: firstDiffNewerIndex)
                            
                            // Rewriting history
                            objectHistoryState.processingState = .replay
                        }
                    }
                } else {
                    // Strange, there are no diffs. Handle it gracefully.
                    assertionFailure("Unexpected state")
                    objectHistoryState.diffs.append(diff)
                    objectHistoryState.processingState = .replay
                }
                
                // See if we ended up updating the diffs. If so, record that it changed.
                if objectHistoryState.diffs.count != originalDiffCount {
                    
                    // If the first diff is an insert, then this is a valid history that we can
                    // act on, so insert into pending updates
                    if let firstDiff = objectHistoryState.diffs.first,
                        case ObjectDiff.insert = firstDiff {
                        pendingUpdates.insert(diff.identifier)
                    } else {
                        // First diff is not an insert, so do not consider as pending update until then.
                    }
                }
            } else {
                // Doesn't exist yet, so create it
                
                let objectHistoryState = ObjectHistoryState(processingState: .replay, diffs: [diff])
                histories[diff.identifier] = objectHistoryState
                
                if case ObjectDiff.insert = diff {
                    pendingUpdates.insert(diff.identifier)
                } else {
                    // If this is NOT an insert operation and it's the first one, do not treat this as
                    // a pending update since we can't act on an object that doesn't have an insert
                    // instruction.
                }
            }
        }
    }
    
    // TODO: Make it so that process() can do a maximum of N updates at a time (to reduce
    // memory consumption). We can keep calling it until MergeResult is empty.
    
    // Go through pending diffs and process the changes they would generate.
    // This mutates our internal state to consider those changes applied.
    func process(objectCache: ObjectCache) -> MergeResult {
        var insertedObjects: [String : DatabaseObject] = [:]
        var removedObjects: [String] = []
        var updatedObjects: [String : DatabaseObject] = [:]
        
        // TODO: Take the first N items in pendingUpdates and only process those
        // so that our list of inserted/removed/updated is a small subset (if needed).
        
        pendingUpdates.forEach { identifier in
            if let objectHistoryState = histories[identifier] {
                switch objectHistoryState.processingState {
                case .fastForward(let nextDiffIndex):
                    if let object = objectCache.fetch(identifier: identifier) {
                        let justNewDiffs = Array(objectHistoryState.diffs.dropFirst(nextDiffIndex))
                        if let updatedObject = UpdatedDatabaseObject(from: justNewDiffs, originalObject: object) {
                            updatedObjects[identifier] = updatedObject
                        } else {
                            removedObjects.append(identifier)
                        }
                    } else {
                        assertionFailure("Object not found in cache")
                    }
                    assert(objectHistoryState.diffs.count > 0)
                    objectHistoryState.processingState = .fastForward(nextDiffIndex: objectHistoryState.diffs.count)
                    
                case .replay:
                    if let oldObject = objectCache.fetch(identifier: identifier) {
                        // Old object exists, so we'll need to replace it (or remove it)
                        _ = oldObject
                        if let newObject = CreateDatabaseObject(from: objectHistoryState.diffs) {
                            updatedObjects[identifier] = newObject
                        } else {
                            removedObjects.append(identifier)
                        }
                    } else {
                        if let newObject = CreateDatabaseObject(from: objectHistoryState.diffs) {
                            insertedObjects[identifier] = newObject
                        } else {
                            // Object got deleted in the end
                        }
                    }
                    assert(objectHistoryState.diffs.count > 0)
                    objectHistoryState.processingState = .fastForward(nextDiffIndex: objectHistoryState.diffs.count)
                }
            } else {
                assertionFailure()
            }
        }
        
        pendingUpdates.removeAll()
        
        return MergeResult(insertedObjects: insertedObjects,
                           removedObjects: removedObjects,
                           updatedObjects: updatedObjects)
    }
    
}
