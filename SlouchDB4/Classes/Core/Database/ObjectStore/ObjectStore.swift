//
//  ObjectStore.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public enum ObjectCountResult {
    case exactly(Int)
    case moreThan(Int)
}

public struct FetchCursor {
    // TODO: whichIndex
    // - identifier, date created, date last modified ?
    public let type: String?
    public let nextObjectOffset: Int
    public let noMoreResults: Bool
    let predicate: ((FetchedDatabaseObject) -> Bool)?
}

public struct FetchedDatabaseObject {
    public let identifier: String
    public let object: DatabaseObject
}

public struct FetchResult {
    public let results: [FetchedDatabaseObject]
    public let cursor: FetchCursor
}

public typealias ObjectDictionary = [String : DatabaseObject]

public protocol ObjectStore {
    func save(to folderUrl: URL)

    // Apply a merge operation
    func apply(mergeResult: MergeResult)
    
    // CRUD operations
    func insert(identifier: String, object: DatabaseObject)
    func replace(identifier: String, object: DatabaseObject)
    func remove(identifier: String)

    // Fetch a single object
    func fetch(identifier: String) -> DatabaseObject?
    
    // Fetch an array of objects, limiting to number of rows, filtering based on predicate
    func fetch(of type: String?, limitCount: Int, predicate: ((FetchedDatabaseObject) -> Bool)?) -> FetchResult
    
    // Fetch more objects from a previous fetch() with predicate
    func fetchMore(cursor: FetchCursor, limitCount: Int) -> FetchResult
    
    // Get count of objects
    func count(of type: String, predicate: ((FetchedDatabaseObject) -> Bool)?) -> ObjectCountResult
}
