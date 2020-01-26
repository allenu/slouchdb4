//
//  ObjectDiff.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/25/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public enum ObjectDiff {
    case insert(identifier: String, timestamp: Date, object: DatabaseObject)
    case update(identifier: String, timestamp: Date, properties: [String : JSONValue])
    case remove(identifier: String, timestamp: Date)
    
    public static func == (lhs: ObjectDiff, rhs: ObjectDiff) -> Bool {
        switch (lhs, rhs) {
        case (.insert(let leftIdentifier, let leftTimestamp, let leftObject),
              .insert(let rightIdentifier, let rightTimestamp, let rightObject)):
            return leftIdentifier == rightIdentifier && leftTimestamp == rightTimestamp && leftObject == rightObject
        
        case (.update(let leftIdentifier, let leftTimestamp, let leftProperties),
              .update(let rightIdentifier, let rightTimestamp, let rightProperties)):
            return leftIdentifier == rightIdentifier && leftTimestamp == rightTimestamp && leftProperties == rightProperties
            
        case (.remove(let leftIdentifier, let leftTimestamp),
              .remove(let rightIdentifier, let rightTimestamp)):
            return leftIdentifier == rightIdentifier && leftTimestamp == rightTimestamp
            
        default:
            return false
        }
    }
    
    var identifier: String {
        switch self {
        case .insert(let identifier, _, _):
            return identifier
            
        case .update(let identifier, _, _):
            return identifier
            
        case .remove(let identifier, _):
            return identifier
        }
    }
    
    var timestamp: Date {
        switch self {
        case .insert(_, let timestamp, _):
            return timestamp
            
        case .update(_, let timestamp, _):
            return timestamp
            
        case .remove(_, let timestamp):
            return timestamp
        }
    }
}
