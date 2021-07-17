//
//  JournalFileReader.swift
//  SlouchDB3
//
//  Created by Allen Ussher on 1/21/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public class JournalFileReader: JournalReadable {
    static let readBufferSize: Int = 512*1024 // 512k read buffer
    static let lowBufferSize: Int = 4*1024  // If we have under 4k of bytes, fetch to fill it up
    // NOTE: The assumption is that 4k is big enough to hold one command. If not, then we have a problem
    // because we may never find a newline in the current buffer.
    
    let url: URL
    var fileHandle: FileHandle
    var fileData: Data?
    var fileDataEOF: Bool
    var byteOffset: UInt64
    let fileLength: UInt64
    
    public init(url: URL) throws {
        self.url = url
        fileHandle = try FileHandle(forReadingFrom: url)
        fileDataEOF = false // assume false
        byteOffset = 0
        
        // Get filesize
        fileHandle.seekToEndOfFile()
        fileLength = fileHandle.offsetInFile
        
        // Go back to start of file
        fileHandle.seek(toFileOffset: 0)
    }
    
    public func close() {
        fileHandle.closeFile()
    }
    
    public func readNextCommands(byteOffset: UInt64, maxCommands: Int) -> JournalReadResult {
//        print("readNextCommands \(self.url.path) -- byteOffset: \(byteOffset)")
        
        let startingOffset = byteOffset
        
        if self.byteOffset != byteOffset {
//            print("seeking to byteOffset \(byteOffset)")
            
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
                return JournalReadResult(commands: [], byteOffset: self.byteOffset)
            }
        }
        
        let readChunksIfNeeded: (Bool) -> Void = { growIfNeeded in
            // Read to fill up to 16k. Only read if on the low end.
            if !self.fileDataEOF {
                if let fileData = self.fileData {
                    // See if we're low on data. If so, fetch to fill up our chunk with more.
                    if growIfNeeded || fileData.count < JournalFileReader.lowBufferSize {
//                        print("\(self.url.path) low on data or growIfNeeded true (\(growIfNeeded))... reading \(JournalFileReader.readBufferSize) bytes")
                        let newData = self.fileHandle.readData(ofLength: JournalFileReader.readBufferSize)
                        
                        if newData.count == 0 {
                            // No more data to read
                            self.fileDataEOF = true
                        }

                        // Combine data
                        self.fileData?.append(newData)
                    } else {
                        // Good enough size...
//                        print("\(self.url.path) good enough size. not reading more. \(fileData.count)")
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
        
        var commands: [Command] = []

        var encounteredEndOfFile: Bool = false
        
        readChunksIfNeeded(false)
        
        // Special case: Before we process the data, we need to make sure we are not pointing to a bad
        // data location. Due to a bug in the past
        
        var readingFirstLine = true
        var numChunksWithoutNewline: Int = 0
        
        while let fileData = self.fileData, !encounteredEndOfFile && commands.count < maxCommands {
            if fileData.count == 0 {
//                print("\(self.url.path) fileData.count == 0")
                encounteredEndOfFile = true
                break
            }
            
            if let newlineIndex = fileData.firstIndex(of: 0x0a) {
                assert(newlineIndex < fileData.count)
                
//                print("\(self.url.path) processing newline")
                
                numChunksWithoutNewline = 0
                
                let jsonCommandData = fileData.prefix(newlineIndex)
                
                let str = String(data: jsonCommandData, encoding: .utf8)
//                print("read jsonCommandData \(str!)")
                
                // Copy remaining bytes into new buffer. Need to do this since firstIndex() above doesn't
                // take into account subsequences from firstIndex/dropFirst operations and so messes up
                // indexing.
                let dataWithJsonCommandRemoved = fileData.dropFirst(newlineIndex + 1) // skip newline as well
                let newBufferSize = dataWithJsonCommandRemoved.count
                dataWithJsonCommandRemoved.withUnsafeBytes( { bytes in
                    self.fileData = Data(bytes: bytes, count: newBufferSize)
                })
                
                
                let successfullyProcessedLine: Bool
                
                if jsonCommandData.count > 0 {
//                    let str = String(data: jsonCommandData, encoding: .utf8)!
//                    print("Here's the data: \(str))")
                    
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let command = try? decoder.decode(Command.self, from: jsonCommandData) {
                        commands.append(command)
                        
                        if let remainingData = self.fileData {
                            encounteredEndOfFile = remainingData.count == 0
                        } else {
                            // No more data
                            encounteredEndOfFile = true
                        }
                        
                        successfullyProcessedLine = true
                    } else {
                        // Unable to read that line as a valid command JSON... Two things could go wrong:
                        // 1. we read a JSON fragment. This can happen due to a known bug in earlier SlouchDB journal readers
                        //    where they could stop reading in the middle of a JSON line and leave the file byte offset
                        //    pointer there. Next time we pick up reading, we'd pick up in the middle of valid JSON and
                        //    not know what to do. The code below in "readingFirstLine" block fixes it.
                        // 2. We read valid JSON but the Command type doesn't match what we expect. This can happen if
                        //    we updated Command's schema and this version of SlouchDB doesn't know what to do with it.
                        //    In such a case, give up b/c we have no hope of processing those commands.
                        
                        if readingFirstLine {
                            // This may be a json *fragment*. It is possible to get into this state with older
                            // versions of SlouchDB4. It can happen when we are reading and
                            // So, as a hack we will re-set the byteOffset to a known good location by
                            // reading bytes backwards until we reach a 0x0a char. We'll then re-set fileData to
                            // nil to force a re-read of data from that point instead.
                            
                            // Manually read data backwards one char at a time until we read 0x0a,
                            // or reach 4k behind us or hit the 0 byte offset, whichever comes first
                            let seekBackLimit: UInt64 = 4096
                            let seekBackByteOffsetThreshold = max(0, startingOffset - seekBackLimit)
                            let seekBackBufferSize: UInt64 = startingOffset - seekBackByteOffsetThreshold
                            
                            if seekBackBufferSize > 0 {
                                // Seek to the offset and read a buffer of that data
                                fileHandle.seek(toFileOffset: seekBackByteOffsetThreshold)
                                let seekBackBuffer = fileHandle.readData(ofLength: Int(seekBackBufferSize))
                                
                                if seekBackBuffer.count > 0 {
                                    // Read a single byte -- NOTE: this is kind of hacky because if .journal is non ASCII
                                    // data, we might read 0x0a as part of a longer UTF char. However, the top-level journal
                                    // file is ASCII and the inner commands have contents that are base64 encoded, so we will
                                    // never have that problem.
                                    
                                    if let lastNewlineCharIndex = seekBackBuffer.lastIndex(of: 0x0a) {
                                        // Yes! We found the first newline char behind us. Re-set the byteOffset
                                        // to point to the first char *after* this on the next loop. Also
                                        // re-set the file seek position to this
                                        
                                        // This the number of characters from the starting offset to the newline
                                        // char.
                                        let deltaToNewline: UInt64 = seekBackBufferSize - UInt64(lastNewlineCharIndex)

                                        // The new byte offset should be adjusted to point to that, then ADD ONE to
                                        // move to the character following it.
                                        let newOffset: UInt64 = startingOffset - deltaToNewline + 1

                                        // We MUST seek to this position so that the next read chunk routine
                                        // can start at the correct location.
                                        fileHandle.seek(toFileOffset: newOffset)
                                        // Also need to re-set the EOF state because we're re-reading a chunk of data
                                        self.fileDataEOF = false
                                        
                                        self.byteOffset = newOffset
                                        self.fileData = nil // This will force a re-read of the byte data at the new offset
                                    } else {
                                        // Unfortunately we could not find a newline char in the seekback buffer.
                                        // We need to quit as we can't recover from this.
                                        assertionFailure()
                                        encounteredEndOfFile = true
                                    }
                                } else {
                                    // Couldn't read any data for some reason. Unrecoverable. Quit.
                                    assertionFailure()
                                    encounteredEndOfFile = true
                                }
                            } else {
                                // Nothing to seek back to! We have to give up then.
                                encounteredEndOfFile = true
                                assertionFailure()
                            }
                        } else {
                            // Can't process JSON, assume EOF. Future proofing as well: if we get here,
                            // we may be processing new commands that do not match the Command style.
//                            print("Cannot understand \(jsonCommandData.base64EncodedString())")
                            encounteredEndOfFile = true
                            assertionFailure()
                        }
                        successfullyProcessedLine = false
                    }
                } else {
//                    print("\(self.url.path) no data on this line")
                    
                    // Data is empty, so ignore this line...
                    if let remainingData = self.fileData {
                        encounteredEndOfFile = remainingData.count == 0
                    } else {
                        // No more data
                        encounteredEndOfFile = true
                    }
                    
                    successfullyProcessedLine = true
                }
                readingFirstLine = false
                
                // Only increment the byteOffset pointer if this was a valid line that we understood.
                // Otherwise, it's possible to read a fragment of JSON if a write is in process from
                // another thread/process, and then the next time we try processing this journal, we
                // start at a bad offset.
                if successfullyProcessedLine {
                    // Update byte offset
                    self.byteOffset = self.byteOffset + UInt64(newlineIndex + 1) // Include newline in total bytes processed for this line
                }
            } else {
                // Can't process buffer. May need to read more chunks.
//                print("\(self.url.path) Couldn't process. May need more chunks")
                numChunksWithoutNewline = numChunksWithoutNewline + 1
            }

            // If more than one chunk encountered without data, grow out as needed
            let growIfNeeded = numChunksWithoutNewline >= 2
            readChunksIfNeeded(growIfNeeded)
        }
        
        // No more data, so return what we have
        return JournalReadResult(commands: commands, byteOffset: self.byteOffset)
    }
}
