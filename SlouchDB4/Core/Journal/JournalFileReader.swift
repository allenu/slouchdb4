//
//  JournalFileReader.swift
//  SlouchDB3
//
//  Created by Allen Ussher on 1/21/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public class JournalFileReader: JournalReadable {
    static let readBufferSize: Int = 512 // 64*1024 // 64k read buffer
    static let lowBufferSize: Int = 4*1024  // If we have under 4k of bytes, fetch to fill it up
    // NOTE: The assumption is that 4k is big enough to hold one diff. If not, then we have a problem
    // because we may never find a newline in the current buffer.
    
    let url: URL
    var fileHandle: FileHandle
    var fileData: Data?
    var fileDataEOF: Bool
    
    public init(url: URL) throws {
        self.url = url
        fileHandle = try FileHandle(forReadingFrom: url)
        fileDataEOF = false // assume false
    }
    
    public func readNext(cursor: JournalCursor, maxCount: Int) -> JournalReadResult {
        guard !cursor.endOfFile else {
            return JournalReadResult(diffs: [], cursor: cursor)
        }
        
        // Read data in chunks of 16k and process it until we run out of bytes to read OR
        if !fileDataEOF {
            if let fileData = fileData {
                // See if we're low on data. If so, fetch to fill up our chunk with more.
                if fileData.count < JournalFileReader.lowBufferSize {
                    let newData = fileHandle.readData(ofLength: JournalFileReader.readBufferSize)
                    
                    if newData.count == 0 {
                        // No more data to read
                        fileDataEOF = true
                    }

                    // Combine data
                    self.fileData?.append(newData)
                } else {
                    // Good enough size...
                }
            } else {
                // If fileData is nil, means no data yet, so load it initially

                // Read readBufferSize
                let data = fileHandle.readData(ofLength: JournalFileReader.readBufferSize)
                self.fileData = data
                
                if data.count == 0 {
                    // No more data to read
                    fileDataEOF = true
                }
            }
        }
        
        var diffs: [ObjectDiff] = []

        var encounteredEndOfFile: Bool = false
        
        while let fileData = fileData, !encounteredEndOfFile {
            if fileData.count == 0 {
                encounteredEndOfFile = true
                break
            }
            
            if let newlineIndex = fileData.firstIndex(of: 0x0a) {
                let jsonDiffData = fileData.prefix(newlineIndex)
                let dataWithJsonDiffRemoved = fileData.dropFirst(newlineIndex + 1) // skip newline as well
                self.fileData = dataWithJsonDiffRemoved
                
                if jsonDiffData.count > 0 {
                    let str = String(data: jsonDiffData, encoding: .utf8)!
                    print("Here's the data: \(str))")
                    
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let jsonRepresentation = try? decoder.decode(ObjectDiffJsonRepresentation.self, from: jsonDiffData) {
                        
                        var objectDiff: ObjectDiff? = nil
                        switch jsonRepresentation.diffType {
                        case .remove:
                            objectDiff = .remove(identifier: jsonRepresentation.identifier, timestamp: jsonRepresentation.timestamp)
                            
                        case .insert:
                            if let properties = jsonRepresentation.properties, let type = jsonRepresentation.type {
                                objectDiff = .insert(identifier: jsonRepresentation.identifier, timestamp: jsonRepresentation.timestamp, object: DatabaseObject(type: type, properties: properties))
                            } else {
                                assertionFailure("Bad insert")
                            }
                            
                        case .update:
                            if let properties = jsonRepresentation.properties {
                                objectDiff = .update(identifier: jsonRepresentation.identifier, timestamp: jsonRepresentation.timestamp, properties: properties)
                            } else {
                                assertionFailure("Bad update")
                            }
                        }
                        
                        if let objectDiff = objectDiff {
                            diffs.append(objectDiff)
                        }
                        
                        if let remainingData = self.fileData {
                            encounteredEndOfFile = remainingData.count == 0
                        } else {
                            // No more data
                            encounteredEndOfFile = true
                        }
                    } else {
                        // Can't process JSON, assume EOF.
                        assertionFailure()
                        encounteredEndOfFile = true
                    }
                } else {
                    // Data is empty, so ignore this line...
                    if let remainingData = self.fileData {
                        encounteredEndOfFile = remainingData.count == 0
                    } else {
                        // No more data
                        encounteredEndOfFile = true
                    }
                }
            } else {
                // Error. Can't process buffer. Assume end of file.
                assertionFailure()
                encounteredEndOfFile = true
            }
        }
        
        // No more data, so return what we have
        return JournalReadResult(diffs: diffs, cursor: cursor)
    }
    
    public func refreshSourceFile() throws {
        // reload file handle. It may fail.

        try fileHandle.close()
        
        fileHandle = try FileHandle(forReadingFrom: url)
        
        // Reset EOF marker
        fileDataEOF = false // assume false
    }
}
