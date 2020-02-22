//
//  InMemObjectStore.swift
//  Pods
//
//  Created by Allen Ussher on 2/22/20.
//

import Foundation
import BTree

public class InMemObjectStore: ObjectStore {
    private var objects: ObjectDictionary

    // WIP: In-mem sorted list of all item indices
    public typealias SortedIdentifiers = SortedSet<String>
    var sortedIdentifiers: SortedIdentifiers

    public init(objects: ObjectDictionary = [:], sortedIdentifiers: [String] = []) {
        self.objects = objects
        self.sortedIdentifiers = SortedIdentifiers(sortedIdentifiers)
    }
    
    public static func create(from folderUrl: URL) -> InMemObjectStore? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var objectStore: InMemObjectStore?
        do {
            let objectStoreUrl = folderUrl.appendingPathComponent("object-store.json")
            let data = try Data(contentsOf: objectStoreUrl)
            let objects: ObjectDictionary = try decoder.decode(ObjectDictionary.self, from: data)
            
            let sortedIdentifiersUrl = folderUrl.appendingPathComponent("sorted-identifiers.json")

            if let data = try? Data(contentsOf: sortedIdentifiersUrl),
                let sortedIdentifiers = try? decoder.decode([String].self, from: data) {
                objectStore = InMemObjectStore(objects: objects, sortedIdentifiers: sortedIdentifiers)
            } else {
                objectStore = nil
            }
        } catch {
            print("Error loading InMemObjectStore")
        }
        
        return objectStore
    }

    public func save(to folderUrl: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let data = try encoder.encode(objects)
            let objectStoreUrl = folderUrl.appendingPathComponent("object-store.json")
            try data.write(to: objectStoreUrl)
            
            let sortedIdentifiersUrl = folderUrl.appendingPathComponent("sorted-identifiers.json")
            let sortedIdentifiersData = try! encoder.encode(Array(sortedIdentifiers))
            try! sortedIdentifiersData.write(to: sortedIdentifiersUrl)
        } catch {
            print("Failed to write to URL: \(error)")
        }
    }
    
    // TODO: Make it so that mergeEnqueued() can be called multiple times
    // since process() will be doing work on chunks only in the future.
    public func apply(mergeResult: MergeResult) {
        if mergeResult.totalChanges > 0 {
            
            // Apply the changes
            mergeResult.insertedObjects.forEach { identifier, object in
                insert(identifier: identifier, object: object)
                
                sortedIdentifiers.insert(identifier)
            }

            mergeResult.updatedObjects.forEach { identifier, object in
                replace(identifier: identifier, object: object)
                
                assert(sortedIdentifiers.contains(identifier))
            }
            
            mergeResult.removedObjects.forEach { identifier in
                remove(identifier: identifier)
                sortedIdentifiers.remove(identifier)
            }
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
    
    public func remove(identifier: String) {
        objects.removeValue(forKey: identifier)
    }

    public func fetch(identifier: String) -> DatabaseObject? {
        return objects[identifier]
    }
    

    public func fetch(of type: String? = nil, limitCount: Int = Database.maxFetchCount, predicate: ((FetchedDatabaseObject) -> Bool)? = nil) -> FetchResult {
        let cursor = FetchCursor(type: type, nextObjectOffset: 0, noMoreResults: false, predicate: predicate)
        return fetchMore(cursor: cursor, limitCount: limitCount)
    }
    
    public func fetchMore(cursor: FetchCursor, limitCount: Int = Database.maxFetchCount) -> FetchResult {
        // If we've gone past the index by now, stop
        var currentPosition = cursor.nextObjectOffset
        var collectedItems: [FetchedDatabaseObject] = []
        while currentPosition < sortedIdentifiers.count && collectedItems.count < limitCount {
            let nextIdentifier = sortedIdentifiers[currentPosition]
            
            let shouldIncludeObject: Bool
            if let object = self.fetch(identifier: nextIdentifier) {
                if let type = cursor.type, object.type != type {
                    shouldIncludeObject = false
                } else if let predicate = cursor.predicate {
                    shouldIncludeObject = predicate(FetchedDatabaseObject(identifier: nextIdentifier, object: object))
                } else {
                    shouldIncludeObject = true
                }
                if shouldIncludeObject {
                    let fetchedObject = FetchedDatabaseObject(identifier: nextIdentifier, object: object)
                    collectedItems.append(fetchedObject)
                }
            } else {
                assertionFailure("Cache mismatch. Identifier shows up in sortedIdentifiers but not in cache")
            }
            
            currentPosition = currentPosition + 1
        }
        
        let noMoreResults = (currentPosition == sortedIdentifiers.count)
        
        let cursor = FetchCursor(type: cursor.type, nextObjectOffset: currentPosition, noMoreResults: noMoreResults, predicate: cursor.predicate)
        let fetchResult = FetchResult(results: collectedItems, cursor: cursor)
        return fetchResult
    }
    
    public func count(of type: String, predicate: ((FetchedDatabaseObject) -> Bool)? = nil) -> ObjectCountResult {
        let fetchResult = fetch(of: type, predicate: predicate)
        
        if fetchResult.results.count == 0 {
            return ObjectCountResult.exactly(0)
        } else if fetchResult.cursor.noMoreResults {
            return ObjectCountResult.exactly(fetchResult.results.count)
        } else {
            return ObjectCountResult.moreThan(fetchResult.results.count)
        }
    }
}
