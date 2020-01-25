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
    
    public func readNext(cursor: JournalCursor, maxCount: Int) -> JournalReadResult {
        let diffsToRead = min(max(0, diffs.count - cursor.nextDiffIndex), maxCount)
        let nextDiffIndex = cursor.nextDiffIndex + diffsToRead
        
        // Assume each diff is stored as a "byte"
        self.byteOffset = self.byteOffset + UInt64(diffsToRead)
        
        let cursor = JournalCursor(nextDiffIndex: nextDiffIndex, byteOffset: byteOffset, endOfFile: diffsToRead == 0)
        return JournalReadResult(diffs: diffs, cursor: cursor)
    }

    public func refreshSourceFile() {
        // Do nothing. This is not file-based.
    }
}
