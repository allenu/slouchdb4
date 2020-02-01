//
//  JournalDataWriter.swift
//  SlouchDB3
//
//  Created by Allen Ussher on 1/22/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public class JournalDataWriter: JournalWritable {
    var diffs: [ObjectDiff]
    public var byteOffset: UInt64

    init(initialDiffs: [ObjectDiff]) {
        self.diffs = initialDiffs
        
        // Treat each diff as one byte for testing only
        byteOffset = UInt64(initialDiffs.count)
    }
    
    public func append(diffs: [ObjectDiff]) {
        self.diffs.append(contentsOf: diffs)
        
        self.byteOffset = self.byteOffset + UInt64(diffs.count)
    }
}
