//
//  ObjectStore.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public typealias ObjectDictionary = [String : DatabaseObject]

public protocol ObjectStore {
    func apply(mergeResult: MergeResult)
    
    func insert(identifier: String, object: DatabaseObject)
    func replace(identifier: String, object: DatabaseObject)
    
    func fetch(identifier: String) -> DatabaseObject?
    func fetch(of type: String?, limitCount: Int, predicate: ((FetchedDatabaseObject) -> Bool)?) -> FetchResult
    func fetchMore(cursor: FetchCursor, limitCount: Int) -> FetchResult
    func count(of type: String, predicate: ((FetchedDatabaseObject) -> Bool)?) -> ObjectCountResult
    
    func remove(identifier: String)
    
    func save(to folderUrl: URL)
}
