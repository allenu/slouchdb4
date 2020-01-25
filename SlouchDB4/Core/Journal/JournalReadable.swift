//
//  JournalReadable.swift
//  SlouchDB3
//
//  Created by Allen Ussher on 1/21/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public struct JournalCursor {
    public let nextDiffIndex: Int
    public let byteOffset: UInt64
    public let endOfFile: Bool
}

public struct JournalReadResult {
    public let diffs: [ObjectDiff]
    public let cursor: JournalCursor
}

public protocol JournalReadable {
    func readNext(cursor: JournalCursor, maxCount: Int) -> JournalReadResult
    
    // If file at path changed, reload it
    func refreshSourceFile() throws
}
