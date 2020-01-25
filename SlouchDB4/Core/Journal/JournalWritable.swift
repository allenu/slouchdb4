//
//  JournalWritable.swift
//  SlouchDB3
//
//  Created by Allen Ussher on 1/21/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public protocol JournalWritable {
    // Appends to a journal and returns the current file size (i.e. the index to which
    // we would append next)
    func append(diffs: [ObjectDiff]) -> UInt64
    
    var byteOffset: UInt64 { get }
}
