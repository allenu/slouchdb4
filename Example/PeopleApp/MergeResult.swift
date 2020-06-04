//
//  MergeResult.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 6/3/20.
//  Copyright © 2020 CocoaPods. All rights reserved.
//

import Foundation

struct MergeResult {
    let insertedObjects: [String : Person]
    let removedObjects: [String]
    let updatedObjects: [String : Person]
    
    var totalChanges: Int {
        return insertedObjects.count + removedObjects.count + updatedObjects.count
    }
}
