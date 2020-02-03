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
    static let lowBufferSize: Int = 256 // 4*1024  // If we have under 4k of bytes, fetch to fill it up
    // NOTE: The assumption is that 4k is big enough to hold one diff. If not, then we have a problem
    // because we may never find a newline in the current buffer.
    
    let url: URL
    var fileHandle: FileHandle
    var fileData: Data?
    var fileDataEOF: Bool
    var byteOffset: UInt64
    
    public init(url: URL) throws {
        self.url = url
        fileHandle = try FileHandle(forReadingFrom: url)
        fileDataEOF = false // assume false
        byteOffset = 0
    }
    
    public func readNextDiffs(byteOffset: UInt64, maxDiffs: Int) -> JournalReadResult {
        if self.byteOffset != byteOffset {
            // Seek to that position
            var seekSucceeded = false
            do {
                try fileHandle.seek(toFileOffset: byteOffset)
//                try fileHandle.seek(toOffset: byteOffset)
                self.byteOffset = byteOffset
                seekSucceeded = true
            } catch {
                // Failed to seek, so assume error
                self.byteOffset = fileHandle.offsetInFile
            }
            
            // If we needed to seek (and even if we failed), we have to clear out our cached fileData
            // and clear out fileDataEOF since they are no longer valid for the seek position.
            self.fileData = nil
            self.fileDataEOF = false
            
            if !seekSucceeded {
                return JournalReadResult(diffs: [], byteOffset: self.byteOffset)
            }
        }
        
        let readChunksIfNeeded = {
            // Read to fill up to 16k. Only read if on the low end.
            if !self.fileDataEOF {
                if let fileData = self.fileData {
                    // See if we're low on data. If so, fetch to fill up our chunk with more.
                    if fileData.count < JournalFileReader.lowBufferSize {
                        let newData = self.fileHandle.readData(ofLength: JournalFileReader.readBufferSize)
                        
                        if newData.count == 0 {
                            // No more data to read
                            self.fileDataEOF = true
                        }

                        // Combine data
                        self.fileData?.append(newData)
                    } else {
                        // Good enough size...
                    }
                } else {
                    // If fileData is nil, means no data yet, so load it initially

                    // Read readBufferSize
                    let data = self.fileHandle.readData(ofLength: JournalFileReader.readBufferSize)
                    self.fileData = data
                    
                    if data.count == 0 {
                        // No more data to read
                        self.fileDataEOF = true
                    }
                }
            }
        }
        
        var diffs: [ObjectDiff] = []

        var encounteredEndOfFile: Bool = false
        
        readChunksIfNeeded()
        while let fileData = self.fileData, !encounteredEndOfFile && diffs.count < maxDiffs {
            if fileData.count == 0 {
                encounteredEndOfFile = true
                break
            }
            
            if let newlineIndex = fileData.firstIndex(of: 0x0a) {
                assert(newlineIndex < fileData.count)
                
                let jsonDiffData = fileData.prefix(newlineIndex)
                
                // Copy remaining bytes into new buffer. Need to do this since firstIndex() above doesn't
                // take into account subsequences from firstIndex/dropFirst operations and so messes up
                // indexing.
                let dataWithJsonDiffRemoved = fileData.dropFirst(newlineIndex + 1) // skip newline as well
                let newBufferSize = dataWithJsonDiffRemoved.count
                dataWithJsonDiffRemoved.withUnsafeBytes( { bytes in
                    self.fileData = Data(bytes: bytes, count: newBufferSize)
                })
                
                // Update byte offset
                self.byteOffset = self.byteOffset + UInt64(newlineIndex + 1) // Include newline in total bytes processed for this line
                
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
                // Can't process buffer. May need to read more chunks.
            }

            readChunksIfNeeded()
        }
        
        // No more data, so return what we have
        return JournalReadResult(diffs: diffs, byteOffset: self.byteOffset)
    }
}
