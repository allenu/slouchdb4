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
}
