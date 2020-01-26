//
//  ObjectCache.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

typealias ObjectDictionary = [String : DatabaseObject]

public protocol ObjectCache {
    func insert(identifier: String, object: DatabaseObject)
    func replace(identifier: String, object: DatabaseObject)
    func fetch(identifier: String) -> DatabaseObject?
    func remove(identifier: String)
}

public class InMemObjectCache: ObjectCache {
    private var objects: ObjectDictionary = [:]
    
    public init() {
    }
    
    public func insert(identifier: String, object: DatabaseObject) {
        let objectExists: Bool = (objects[identifier] != nil)
        assert(!objectExists)
        
        if !objectExists {
            objects[identifier] = object
        }
    }
    
    public func replace(identifier: String, object: DatabaseObject) {
        let objectExists = (objects[identifier] != nil)
        assert(objectExists)

        objects[identifier] = object
    }
    
    public func fetch(identifier: String) -> DatabaseObject? {
        return objects[identifier]
    }
    
    public func remove(identifier: String) {
        objects.removeValue(forKey: identifier)
    }
}
