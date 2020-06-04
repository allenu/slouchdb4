//
//  JournalFileWriter.swift
//  SlouchDB3
//
//  Created by Allen Ussher on 1/21/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public class JournalFileWriter: JournalWritable {
    let fileHandle: FileHandle
    public var byteOffset: UInt64
    var isClosed: Bool = false
    
    var url: URL
    
    var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    
    public init(url: URL) throws {
        self.url = url
        
        do {
            let fileHandle = try FileHandle(forWritingTo: url)
            self.fileHandle = fileHandle
            self.byteOffset = self.fileHandle.seekToEndOfFile()
        } catch {
            let nserror = error as NSError
            if nserror.domain == NSCocoaErrorDomain && nserror.code == 4 {
                // NSCocoaErrorDomain Code 4 == "No such file"
                // New file, so create it first
                do {
                    try Data().write(to: url, options: [])
                    self.fileHandle = try FileHandle(forWritingTo: url)
                    self.byteOffset = 0
                } catch {
                    throw error
                }
            } else {
                throw error
            }
        }
    }
    
    deinit {
        if !isClosed {
            fileHandle.closeFile()
            /*
            do {
                try fileHandle.close()
            } catch {
                print("Error closing file: \(error)")
            }
 */
        }
    }
    
    public func close() {
        guard !isClosed else { return }
        
        fileHandle.closeFile()

//        do {
//            try fileHandle.close()
//            isClosed = true
//        } catch {
//            print("Error closing file \(error)")
//        }
    }
    
    public func append(commands: [Command]) {
        // Each command goes on its own line, separated by newlines
        commands.forEach { command in
            let commandData = try! encoder.encode(command)
            fileHandle.write(commandData)
            
            let newline = "\n"
            let newlineData = newline.data(using: .utf8)!
            fileHandle.write(newlineData)
        }
        
        self.byteOffset = fileHandle.offsetInFile
    }
}
