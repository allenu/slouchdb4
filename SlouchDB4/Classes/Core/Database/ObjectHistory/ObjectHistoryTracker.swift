//
//  ObjectHistoryTracker.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public enum ObjectHistoryProcessingState {
    case fastForward(nextDiffIndex: Int)
    case replay
}

public protocol ObjectProvider: class {
    func object(for identifier: String) -> DatabaseObject?
}

typealias ObjectHistory =  [ObjectDiff]

public class ObjectHistoryState {
    public var processingState: ObjectHistoryProcessingState
    public var diffs: [ObjectDiff]
    
    public init(processingState: ObjectHistoryProcessingState,
         diffs: [ObjectDiff] = []) {
        self.processingState = processingState
        self.diffs = diffs
    }
}

public struct MergeResult {
    public let insertedObjects: [String : DatabaseObject]
    public let removedObjects: [String]
    public let updatedObjects: [String : DatabaseObject]
    
    public var totalChanges: Int {
        return insertedObjects.count + removedObjects.count + updatedObjects.count
    }
}

public class ObjectHistoryTracker {
    let objectHistoryStore: ObjectHistoryStoring
    
    public init(objectHistoryStore: ObjectHistoryStoring) {
        self.objectHistoryStore = objectHistoryStore
    }
    
    func save(to folderUrl: URL) {
        objectHistoryStore.save(to: folderUrl)
    }
    
    // This queues up the diffs provided and updates the histories of each object.
    public func enqueue(diffs: [ObjectDiff]) {
        diffs.forEach { diff in
            if let objectHistoryState = objectHistoryStore.objectHistoryState(for: diff.identifier) {
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
                        objectHistoryStore.insertPendingUpdate(for: diff.identifier)
                    } else {
                        // First diff is not an insert, so do not consider as pending update until then.
                    }
                }
            } else {
                // Doesn't exist yet, so create it
                
                let objectHistoryState = ObjectHistoryState(processingState: .replay, diffs: [diff])
                objectHistoryStore.update(objectHistoryState: objectHistoryState, for: diff.identifier)
                
                if case ObjectDiff.insert = diff {
                    objectHistoryStore.insertPendingUpdate(for: diff.identifier)
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
    func process(objectProvider: ObjectProvider) -> MergeResult {
        var insertedObjects: [String : DatabaseObject] = [:]
        var removedObjects: [String] = []
        var updatedObjects: [String : DatabaseObject] = [:]
        
        // TODO: Take the first N items in pendingUpdates and only process those
        // so that our list of inserted/removed/updated is a small subset (if needed).
        
        let pendingUpdates = objectHistoryStore.pendingUpdates()
        
        pendingUpdates.forEach { identifier in
            if let objectHistoryState = objectHistoryStore.objectHistoryState(for: identifier) {
                switch objectHistoryState.processingState {
                case .fastForward(let nextDiffIndex):
                    if let object = objectProvider.object(for: identifier) {
                        let justNewDiffs = Array(objectHistoryState.diffs.dropFirst(nextDiffIndex))
                        if let updatedObject = UpdatedDatabaseObject(from: justNewDiffs, originalObject: object) {
                            updatedObjects[identifier] = updatedObject
                        } else {
                            print("WARNING: \(identifier) removed during ffwd")
                            removedObjects.append(identifier)
                        }
                        assert(objectHistoryState.diffs.count > 0)
                        objectHistoryState.processingState = .fastForward(nextDiffIndex: objectHistoryState.diffs.count)
                    } else {
                        //assertionFailure("Object not found in cache")
                        print("WARNING: \(identifier) Encountered an update on an object that has not yet been inserted. Will reset to .replay and hope the insert happens first.")
                        objectHistoryState.processingState = .replay
                    }
                    
                case .replay:
                    if let oldObject = objectProvider.object(for: identifier) {
                        // Old object exists, so we'll need to replace it (or remove it)
                        _ = oldObject
                        if let newObject = CreateDatabaseObject(from: objectHistoryState.diffs) {
                            updatedObjects[identifier] = newObject
                        } else {
                            print("WARNING: \(identifier) removed during replay")
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
            
            objectHistoryStore.removePendingUpdate(for: identifier)
        }
        
        return MergeResult(insertedObjects: insertedObjects,
                           removedObjects: removedObjects,
                           updatedObjects: updatedObjects)
    }
}
