//
//  ObjectCache.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public typealias ObjectDictionary = [String : DatabaseObject]

public protocol ObjectCache {
    func insert(identifier: String, object: DatabaseObject)
    func replace(identifier: String, object: DatabaseObject)
    func fetch(identifier: String) -> DatabaseObject?
    func remove(identifier: String)
    
    func save(to fileUrl: URL)
}

public class InMemObjectCache: ObjectCache {
    private var objects: ObjectDictionary
    
    public init(objects: ObjectDictionary = [:]) {
        self.objects = objects
    }
    
    public static func create(from fileUrl: URL) -> InMemObjectCache? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var objectCache: InMemObjectCache?
        do {
            let data = try Data(contentsOf: fileUrl)
            let objects: ObjectDictionary = try decoder.decode(ObjectDictionary.self, from: data)
            objectCache = InMemObjectCache(objects: objects)
        } catch {
            print("Error loading InMemObjectCache")
        }
        
        return objectCache
    }

    public func save(to fileUrl: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let data = try encoder.encode(objects)
            try data.write(to: fileUrl)
        } catch {
            print("Failed to write to URL: \(error)")
        }
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
