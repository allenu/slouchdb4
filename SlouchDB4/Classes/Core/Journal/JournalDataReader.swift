//
//  JournalDataReader.swift
//  SlouchDB3
//
//  Created by Allen Ussher on 1/22/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public class JournalDataReader: JournalReadable {
    let diffs: [ObjectDiff]
    var byteOffset: UInt64 = 0
    
    init(initialDiffs: [ObjectDiff]) {
        self.diffs = initialDiffs
    }
    
    public func readNextDiffs(byteOffset: UInt64, maxDiffs: Int) -> JournalReadResult {
        if self.byteOffset != byteOffset {
            // Simulate a seek to that position
            self.byteOffset = byteOffset
        }

        let diffsToRead = min(max(0, diffs.count - Int(self.byteOffset)), maxDiffs)
        
        // Assume each diff is stored as a "byte" so we can count diffs easily
        self.byteOffset = self.byteOffset + UInt64(diffsToRead)
        
        return JournalReadResult(diffs: diffs, byteOffset: self.byteOffset)
    }
}
