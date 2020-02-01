//
//  DatabaseTests.swift
//  SlouchDB4Tests
//
//  Created by Allen Ussher on 1/25/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import XCTest
@testable import SlouchDB4

class DatabaseTests: XCTestCase {

    func testInsertDiff() {
        let tracker = ObjectHistoryTracker()
        let objectCache = InMemObjectCache()
        let database = Database(objectCache: objectCache, objectHistoryTracker: tracker)
        
        let now = Date()
        let object = DatabaseObject(type: "person", properties: ["name" : .string("John")])
        let diff = ObjectDiff.insert(identifier: "1", timestamp: now, object: object)
        database.enqueue(diffs: [diff])
        
        database.mergeEnqueued()
        
        if let fetchedObject = database.fetch(identifier: "1") {
            XCTAssert(fetchedObject.properties["name"] == JSONValue.string("John"))
        } else {
            XCTFail()
        }
    }

    func testUpdatedDiff() {
        let tracker = ObjectHistoryTracker()
        let objectCache = InMemObjectCache()
        let database = Database(objectCache: objectCache, objectHistoryTracker: tracker)
        
        let now = Date()
        let object = DatabaseObject(type: "person", properties: ["name" : .string("John")])
        let diff = ObjectDiff.insert(identifier: "1", timestamp: now, object: object)
        database.enqueue(diffs: [diff])
        
        database.mergeEnqueued()
        
        if let fetchedObject = database.fetch(identifier: "1") {
            XCTAssert(fetchedObject.properties["name"] == JSONValue.string("John"))
        } else {
            XCTFail()
        }

        let newProperties: [String : JSONValue] = [
            "name" : .string("Fred")
        ]
        let updateDiff = ObjectDiff.update(identifier: "1", timestamp: now.addingTimeInterval(1.0), properties: newProperties)
        
        database.enqueue(diffs: [updateDiff])
        database.mergeEnqueued()
        
        if let updatedFetchedObject = database.fetch(identifier: "1") {
            XCTAssert(updatedFetchedObject.properties["name"] == JSONValue.string("Fred"))
        } else {
            XCTFail()
        }
    }

    func testRemoveDiff() {
        let tracker = ObjectHistoryTracker()
        let objectCache = InMemObjectCache()
        let database = Database(objectCache: objectCache, objectHistoryTracker: tracker)
        
        let now = Date()
        let object = DatabaseObject(type: "person", properties: ["name" : .string("John")])
        let diff = ObjectDiff.insert(identifier: "1", timestamp: now, object: object)
        database.enqueue(diffs: [diff])
        
        database.mergeEnqueued()
        
        if let fetchedObject = database.fetch(identifier: "1") {
            XCTAssert(fetchedObject.properties["name"] == JSONValue.string("John"))
        } else {
            XCTFail()
        }

        let removeDiff = ObjectDiff.remove(identifier: "1", timestamp: now.addingTimeInterval(1.0))
        database.enqueue(diffs: [removeDiff])
        database.mergeEnqueued()
        
        let removedFetchedObject = database.fetch(identifier: "1")
        XCTAssertNil(removedFetchedObject)
    }
    
    func testSaveAndLoad() {
        let directory = NSTemporaryDirectory()
        let pathName = NSUUID().uuidString
        let tempUrl = NSURL.fileURL(withPathComponents: [directory, pathName])!
        try! FileManager.default.createDirectory(at: tempUrl, withIntermediateDirectories: true, attributes: nil)

        
        let tracker = ObjectHistoryTracker()
        let objectCache = InMemObjectCache()
        let database = Database(objectCache: objectCache, objectHistoryTracker: tracker)
        
        let now = Date()
        let object1 = DatabaseObject(type: "person", properties: ["name" : .string("Alice")])
        let diff1 = ObjectDiff.insert(identifier: "1", timestamp: now, object: object1)

        let object2 = DatabaseObject(type: "person", properties: ["name" : .string("Bob")])
        let diff2 = ObjectDiff.insert(identifier: "2", timestamp: now.addingTimeInterval(1.0), object: object2)
        database.enqueue(diffs: [diff1, diff2])
        
        // NOTE: Inserts are queued but not executed yet
        
        XCTAssert(tracker.pendingUpdates.count == 2)
        XCTAssert(objectCache.fetch(identifier: "1") == nil)
        XCTAssert(objectCache.fetch(identifier: "2") == nil)

        let trackerPath = tempUrl.appendingPathComponent("object-tracker.json")
        tracker.save(to: trackerPath)
        let objectCachePath = tempUrl.appendingPathComponent("object-cache.json")
        objectCache.save(to: objectCachePath)

        let newObjectCache = InMemObjectCache.create(from: objectCachePath)!
        let newTracker = ObjectHistoryTracker.create(from: trackerPath)!
        XCTAssert(newTracker.pendingUpdates.count == 2)
        let history1 = newTracker.histories["1"]!
        XCTAssert(history1.diffs.count == 1)
        
        XCTAssert(newTracker.histories["2"] != nil)
        XCTAssert(newObjectCache.fetch(identifier: "1") == nil)
        XCTAssert(newObjectCache.fetch(identifier: "2") == nil)

        database.mergeEnqueued()

        //
        let secondPathName = NSUUID().uuidString
        let secondTempUrl = NSURL.fileURL(withPathComponents: [directory, secondPathName])!
        try! FileManager.default.createDirectory(at: secondTempUrl, withIntermediateDirectories: true, attributes: nil)

        let secondTrackerPath = tempUrl.appendingPathComponent("object-tracker.json")
        tracker.save(to: secondTrackerPath)
        let secondObjectCachePath = tempUrl.appendingPathComponent("object-cache.json")
        objectCache.save(to: secondObjectCachePath)
        
        let secondNewObjectCache = InMemObjectCache.create(from: secondObjectCachePath)!
        let secondNewTracker = ObjectHistoryTracker.create(from: secondTrackerPath)!
        XCTAssert(secondNewTracker.pendingUpdates.count == 0) // No pending updates this time!
        
        // TODO: more tests on the loaded data here
        XCTAssert(secondNewObjectCache.fetch(identifier: "1") != nil)
        XCTAssert(secondNewObjectCache.fetch(identifier: "2") != nil)

    }
    
}
