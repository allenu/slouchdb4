//
//  DatabaseObject.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public struct DatabaseObject: Codable, Equatable {
    public static func == (lhs: DatabaseObject, rhs: DatabaseObject) -> Bool {
        return lhs.type == rhs.type && lhs.properties == rhs.properties
    }
    
    public let type: String
    public let properties: [String : JSONValue]
    
    public init(type: String,
                properties: [String : JSONValue]) {
        self.type = type
        self.properties = properties
    }
}

// Returns nil if object is deleted during playback
public func CreateDatabaseObject(from diffs: [ObjectDiff]) -> DatabaseObject? {
    var createdObject: DatabaseObject? = nil
    
    diffs.forEach { diff in
        switch diff {
        case .insert(_, _, let object):
            createdObject = object
            
        case .update(_, _, let properties):
            if let oldCreatedObject = createdObject {
                let newProperties = oldCreatedObject.properties.merging(properties, uniquingKeysWith: { $1 })
                createdObject = DatabaseObject(type: oldCreatedObject.type, properties: newProperties)
            } else {
                // If createdObject is nil, just means we didn't have the instruction to insert it yet.
                // This can happen if we're missing a journal.
                // assertionFailure("Looks like we're missing a journal")
                NSLog("We're missing an object to update. No-op.")
            }
            
        case .remove:
            createdObject = nil
        }
    }
    
    return createdObject
}

// Returns nil if object is deleted during playback
func UpdatedDatabaseObject(from diffs: [ObjectDiff], originalObject: DatabaseObject) -> DatabaseObject? {
    var updatedObject: DatabaseObject? = originalObject
    
    diffs.forEach { diff in
        switch diff {
        case .insert(let identifier, _, let object):
            // assertionFailure("Did not expect an insert on an existing object.")
            print("WARNING: \(identifier) Did not expect insert on existing object")
            // Fail gracefully and just replace it...
            updatedObject = object
            
        case .update(_, _, let properties):
            assert(updatedObject != nil)
            if let oldUpdatedObject = updatedObject {
                let newProperties = oldUpdatedObject.properties.merging(properties, uniquingKeysWith: { $1 })
                updatedObject = DatabaseObject(type: oldUpdatedObject.type, properties: newProperties)
            } else {
                // If createdObject is nil, just means we didn't have the instruction to insert it yet.
                // This can happen if we're missing a journal.
                assertionFailure("Looks like we're missing a journal")
            }
            
        case .remove:
            updatedObject = nil
        }
    }
    
    return updatedObject
}
