//
//  ObjectHistoryTrackerTests.swift
//  SlouchDB4Tests
//
//  Created by Allen Ussher on 1/25/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import XCTest
@testable import SlouchDB4

class ObjectHistoryTrackerTests: XCTestCase {

    func testExample() {
        // Use recording to get started writing UI tests.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }
    
    func testProcessNothing() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let objectStore = InMemObjectStore()

        XCTAssert(tracker.pendingUpdates.count == 0)

        let mergeResult = tracker.process(objectStore: objectStore)
        
        XCTAssert(mergeResult.totalChanges == 0)
        XCTAssert(tracker.pendingUpdates.count == 0)
    }

    func testSingleDiff() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let objectStore = InMemObjectStore()
        
        let now = Date()
        let object = DatabaseObject(type: "person", properties: ["name" : .string("John")])
        let diff = ObjectDiff.insert(identifier: "1", timestamp: now, object: object)
        tracker.enqueue(diffs: [diff])
        
        XCTAssert(tracker.pendingUpdates.count == 1)

        let mergeResult = tracker.process(objectStore: objectStore)
        
        XCTAssert(mergeResult.totalChanges == 1)
        XCTAssert(mergeResult.insertedObjects.count == 1)
        XCTAssert(tracker.pendingUpdates.count == 0)
    }

    func testTwoSeparateDiffs() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let objectStore = InMemObjectStore()
        
        let now = Date()
        let firstObject = DatabaseObject(type: "person", properties: ["name" : .string("John")])
        let secondObject = DatabaseObject(type: "person", properties: ["name" : .string("Frank")])
        let firstDiff = ObjectDiff.insert(identifier: "1", timestamp: now, object: firstObject)
        let secondDiff = ObjectDiff.insert(identifier: "2", timestamp: now, object: secondObject)
        tracker.enqueue(diffs: [firstDiff, secondDiff])
        
        XCTAssert(tracker.pendingUpdates.count == 2)

        let mergeResult = tracker.process(objectStore: objectStore)
        
        XCTAssert(mergeResult.totalChanges == 2)
        XCTAssert(mergeResult.insertedObjects.count == 2)
        XCTAssert(tracker.pendingUpdates.count == 0)
    }
    
    func testOrderDoesntMatter_InSameEnqueue() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let objectStore = InMemObjectStore()
        
        // Diffs just use date, not order of enqueue
        let now = Date()
        let firstObject = DatabaseObject(type: "person", properties: ["name" : .string("First")])
        let firstDiff = ObjectDiff.insert(identifier: "1", timestamp: now, object: firstObject)
        let secondDiff = ObjectDiff.update(identifier: "1", timestamp: now.addingTimeInterval(1.0), properties: ["name" : .string("Second")])
        tracker.enqueue(diffs: [secondDiff, firstDiff])
        
        // Updates go to same object
        XCTAssert(tracker.pendingUpdates.count == 1)

        let mergeResult = tracker.process(objectStore: objectStore)
        
        XCTAssert(mergeResult.totalChanges == 1)
        XCTAssert(mergeResult.insertedObjects.count == 1)
        XCTAssert(tracker.pendingUpdates.count == 0)
        
        let object = mergeResult.insertedObjects.first!.value
        XCTAssert(object.properties["name"] == JSONValue.string("Second"))
    }

    func testOrderDoesntMatter_InDifferentEnqueues() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let objectStore = InMemObjectStore()
        
        // Diffs just use date, not order of enqueue
        let now = Date()
        let firstObject = DatabaseObject(type: "person", properties: ["name" : .string("First")])
        let firstDiff = ObjectDiff.insert(identifier: "1", timestamp: now, object: firstObject)
        let secondDiff = ObjectDiff.update(identifier: "1", timestamp: now.addingTimeInterval(1.0), properties: ["name" : .string("Second")])
        tracker.enqueue(diffs: [secondDiff])
        tracker.enqueue(diffs: [firstDiff])
        
        // Updates go to same object
        XCTAssert(tracker.pendingUpdates.count == 1)

        let mergeResult = tracker.process(objectStore: objectStore)
        
        XCTAssert(mergeResult.totalChanges == 1)
        XCTAssert(mergeResult.insertedObjects.count == 1)
        XCTAssert(tracker.pendingUpdates.count == 0)
        
        let object = mergeResult.insertedObjects.first!.value
        XCTAssert(object.properties["name"] == JSONValue.string("Second"))
    }
    
    // We have three diffs, but only 1st and 3rd are known at first. Later, 2nd diff comes in
    // and should be incorporated. (May lead to a "replay" situation internally.)
    func testInsertingMissingDiffLater_WhenNotInObjectStore() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let objectStore = InMemObjectStore()
        
        // Diffs just use date, not order of enqueue
        let now = Date()
        let firstObject = DatabaseObject(type: "person", properties: ["name" : .string("First")])
        let firstDiff = ObjectDiff.insert(identifier: "1", timestamp: now, object: firstObject)
        let secondDiff = ObjectDiff.update(identifier: "1", timestamp: now.addingTimeInterval(1.0), properties: ["name" : .string("Second")])
        let thirdDiff = ObjectDiff.update(identifier: "1", timestamp: now.addingTimeInterval(2.0), properties: ["age" : .int(23)])
        tracker.enqueue(diffs: [thirdDiff])
        tracker.enqueue(diffs: [firstDiff])
        
        // Updates go to same object
        XCTAssert(tracker.pendingUpdates.count == 1)

        let mergeResult = tracker.process(objectStore: objectStore)
        
        XCTAssert(mergeResult.totalChanges == 1)
        XCTAssert(mergeResult.insertedObjects.count == 1)
        XCTAssert(tracker.pendingUpdates.count == 0)
        
        let object = mergeResult.insertedObjects.first!.value
        XCTAssert(object.properties["name"] == JSONValue.string("First"))
        XCTAssert(object.properties["age"] == JSONValue.int(23))
        
        // Now apply 2nd item
        tracker.enqueue(diffs: [secondDiff])
        
        XCTAssert(tracker.pendingUpdates.count == 1)
        
        let updatedMergeResult = tracker.process(objectStore: objectStore)
        
        XCTAssert(updatedMergeResult.totalChanges == 1)
        XCTAssert(updatedMergeResult.insertedObjects.count == 1)    // Should show up as an "insert" still because it's not in objectStore
        XCTAssert(tracker.pendingUpdates.count == 0)
        
        let secondObject = updatedMergeResult.insertedObjects.first!.value
        XCTAssert(secondObject.properties["name"] == JSONValue.string("Second"))  // Now "Second" name should show
        XCTAssert(secondObject.properties["age"] == JSONValue.int(23))
    }

    func testInsertingMissingDiffLater_WhenAlreadyInObjectStore() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let objectStore = InMemObjectStore()
        
        // Diffs just use date, not order of enqueue
        let now = Date()
        let firstObject = DatabaseObject(type: "person", properties: ["name" : .string("First")])
        let firstDiff = ObjectDiff.insert(identifier: "1", timestamp: now, object: firstObject)
        let secondDiff = ObjectDiff.update(identifier: "1", timestamp: now.addingTimeInterval(1.0), properties: ["name" : .string("Second")])
        let thirdDiff = ObjectDiff.update(identifier: "1", timestamp: now.addingTimeInterval(2.0), properties: ["age" : .int(23)])
        tracker.enqueue(diffs: [thirdDiff])
        tracker.enqueue(diffs: [firstDiff])
        
        // Updates go to same object
        XCTAssert(tracker.pendingUpdates.count == 1)

        let mergeResult = tracker.process(objectStore: objectStore)
        
        XCTAssert(mergeResult.totalChanges == 1)
        XCTAssert(mergeResult.insertedObjects.count == 1)
        XCTAssert(tracker.pendingUpdates.count == 0)
        
        let object = mergeResult.insertedObjects.first!.value
        XCTAssert(object.properties["name"] == JSONValue.string("First"))
        XCTAssert(object.properties["age"] == JSONValue.int(23))
        
        // Insert object into cache so that we are forced to update in-place
        objectStore.insert(identifier: "1", object: object)
        
        // Now apply 2nd item
        tracker.enqueue(diffs: [secondDiff])
        
        XCTAssert(tracker.pendingUpdates.count == 1)
        
        let updatedMergeResult = tracker.process(objectStore: objectStore)
        
        XCTAssert(updatedMergeResult.totalChanges == 1)
        XCTAssert(updatedMergeResult.updatedObjects.count == 1)    // Now shows up as "insert"
        XCTAssert(tracker.pendingUpdates.count == 0)
        
        let secondObject = updatedMergeResult.updatedObjects.first!.value
        XCTAssert(secondObject.properties["name"] == JSONValue.string("Second"))  // Now "Second" name should show
        XCTAssert(secondObject.properties["age"] == JSONValue.int(23))
    }

    func testUpdatesOnNonExistentObjectShouldDoNothing() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let objectStore = InMemObjectStore()
        
        // Diffs just use date, not order of enqueue
        let now = Date()
        let thirdDiff = ObjectDiff.update(identifier: "1", timestamp: now.addingTimeInterval(2.0), properties: ["age" : .int(23)])
        
        // Let's update a property of non-existent object
        tracker.enqueue(diffs: [thirdDiff])
        
        // Should not be a pending update
        XCTAssert(tracker.pendingUpdates.count == 0)

        let mergeResult = tracker.process(objectStore: objectStore)
        
        // Should do nothing
        XCTAssert(mergeResult.totalChanges == 0)
        XCTAssert(mergeResult.insertedObjects.count == 0)
        XCTAssert(tracker.pendingUpdates.count == 0)
    }

    func testInsertAndRemoveDiffsShouldStillHaveHistory() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let objectStore = InMemObjectStore()
        
        // Diffs just use date, not order of enqueue
        let now = Date()
        let firstObject = DatabaseObject(type: "person", properties: ["name" : .string("First")])
        let firstDiff = ObjectDiff.insert(identifier: "1", timestamp: now, object: firstObject)
        let secondDiff = ObjectDiff.remove(identifier: "1", timestamp: now.addingTimeInterval(1.0))
        
        // Let's update a property of non-existent object
        tracker.enqueue(diffs: [firstDiff])
        tracker.enqueue(diffs: [secondDiff])
        
        // Should be a pending update still (we don't know if history will be deleted yet, unfortunately)
        XCTAssert(tracker.pendingUpdates.count == 1)

        let mergeResult = tracker.process(objectStore: objectStore)
        
        // When we merge, we'll find there are no outcomes
        XCTAssert(mergeResult.totalChanges == 0)
        XCTAssert(tracker.pendingUpdates.count == 0)
        
        // Should still have a history though of both insert and delete
        XCTAssert(tracker.histories.first!.value.diffs.count == 2)
    }

    func testSameDiffShouldNotBeInserted() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)

        // Diffs just use date, not order of enqueue
        let now = Date()
        let firstObject = DatabaseObject(type: "person", properties: ["name" : .string("First")])
        let firstDiff = ObjectDiff.insert(identifier: "1", timestamp: now, object: firstObject)
        let secondDiff = ObjectDiff.remove(identifier: "1", timestamp: now.addingTimeInterval(1.0))
        
        // Let's update a property of non-existent object
        tracker.enqueue(diffs: [firstDiff])
        tracker.enqueue(diffs: [secondDiff])
        
        // Should only have 2 diffs in the history
        XCTAssert(tracker.histories.first!.value.diffs.count == 2)

        tracker.enqueue(diffs: [firstDiff]) // Insert firstDiff yet again
        
        // Should STILL only have 2 diffs in the history
        XCTAssert(tracker.histories.first!.value.diffs.count == 2)
    }

    func testInsertedDiffShouldCauseReplay() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let objectStore = InMemObjectStore()
        
        // Diffs just use date, not order of enqueue
        let now = Date()
        let firstObject = DatabaseObject(type: "person", properties: ["name" : .string("First")])
        let firstDiff = ObjectDiff.insert(identifier: "1", timestamp: now, object: firstObject)
        let secondDiff = ObjectDiff.update(identifier: "1", timestamp: now.addingTimeInterval(1.0), properties: ["name" : .string("Second")])
        let thirdDiff = ObjectDiff.update(identifier: "1", timestamp: now.addingTimeInterval(2.0), properties: ["age" : .int(23)])

        // Let's update a property of non-existent object
        tracker.enqueue(diffs: [firstDiff])
        tracker.enqueue(diffs: [thirdDiff])
        
        let mergeResult = tracker.process(objectStore: objectStore)
        
        let object = mergeResult.insertedObjects.first!.value
        XCTAssert(object.properties["name"] == JSONValue.string("First"))
        XCTAssert(object.properties["age"] == JSONValue.int(23))
        
        // Insert object into cache so that we are forced to update in-place.
        objectStore.insert(identifier: "1", object: object)
        
        XCTAssert(tracker.histories.first!.value.diffs.count == 2)

        // History state should be .fastForward right now
        
        let history = tracker.histories["1"]!
        if case ObjectHistoryProcessingState.fastForward(let nextDiffIndex) = history.processingState {
            // Next diff should be "2" since we have 0 and 1 already
            XCTAssert(nextDiffIndex == 2)
        } else {
            XCTFail()
        }

        // Now if we enqueue second diff, we must insert it into our history, causing the state to be "replay"
        tracker.enqueue(diffs: [secondDiff])

        let updatedHistory = tracker.histories["1"]!
        if case ObjectHistoryProcessingState.replay = updatedHistory.processingState {
            // Success
        } else {
            XCTFail()
        }

        XCTAssert(tracker.histories.first!.value.diffs.count == 3)
    }
    
    func testRemoveExistingObject() {
        let objectHistoryStore = InMemObjectHistoryStore()
        let tracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let objectStore = InMemObjectStore()
        
        // Diffs just use date, not order of enqueue
        let now = Date()
        let firstObject = DatabaseObject(type: "person", properties: ["name" : .string("First")])
        let firstDiff = ObjectDiff.insert(identifier: "1", timestamp: now, object: firstObject)
        
        tracker.enqueue(diffs: [firstDiff])
        let firstMerge = tracker.process(objectStore: objectStore)
        
        let object = firstMerge.insertedObjects.first!.value
        objectStore.insert(identifier: "1", object: object)
        
        
        // Now delete it
        let secondDiff = ObjectDiff.remove(identifier: "1", timestamp: now.addingTimeInterval(1.0))
        tracker.enqueue(diffs: [secondDiff])

        let secondMerge = tracker.process(objectStore: objectStore)
        XCTAssert(secondMerge.totalChanges == 1)
        XCTAssert(secondMerge.removedObjects.count == 1)
    }

    // TODO: Test that process() does things in chunks if we have too many pending updates to process.
}
