//
//  JournalReadable.swift
//  SlouchDB3
//
//  Created by Allen Ussher on 1/21/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public struct JournalCursor: Codable {
    public let nextCommandIndex: Int
    public let byteOffset: UInt64
    public let endOfFile: Bool
}

public struct JournalReadResult {
    public let commands: [Command]
    public let byteOffset: UInt64
    
    public init(commands: [Command], byteOffset: UInt64) {
        self.commands = commands
        self.byteOffset = byteOffset
    }
}

public protocol JournalReadable {
    func readNextCommands(byteOffset: UInt64, maxCommands: Int) -> JournalReadResult
    func close()
}
