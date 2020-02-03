//
//  JournalFileManager.swift
//  Pods
//
//  Created by Allen Ussher on 2/1/20.
//

import Foundation

// Life of JournalFileManager:
//
// 1. First initialized for an empty non-saved Document
//    - rootFolderUrl provided is some temporary folder
//    - create locals/ subfolder
//    - create remotes/ subfolder
//    - when writeLocal(diffs:,to:) is called, destination stream is created/opened if not
//      done so yet, and appended to
//
// 2. Save is called on a URL
//    - if URL is different from one we initialized it with, means we are saving elsewhere
//      - close all locals
//      - create locals/ and remotes/
//      - copy all locals to destination
//      - copy all remotes to destination
//      - clear out all local writers (they'll get re-initialized on next write() call
//    - if URL is same, no need to do anything
//

public class JournalFileManager: JournalFileManaging {
    public var rootFolderUrl: URL
    var localWriters: [String : JournalFileWriter] = [:]
    var remoteReaders: [String : JournalFileReader] = [:]
    
    static func ensureDirectoryExists(url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    static func ensureLocalsAndRemotesDirectoriesExist(url: URL) {
        let localsFolder = url.appendingPathComponent("locals")
        JournalFileManager.ensureDirectoryExists(url: localsFolder)
        
        let remotesFolder = url.appendingPathComponent("remotes")
        JournalFileManager.ensureDirectoryExists(url: remotesFolder)
    }
    
    static func copyFiles(from sourceFolder: URL, to destinationFolder: URL) {
        let fileEnumerator = FileManager.default.enumerator(at: sourceFolder, includingPropertiesForKeys: nil)
        while let element = fileEnumerator?.nextObject() {
            if let fileUrl = element as? URL {
                let destinationUrl = destinationFolder.appendingPathComponent(fileUrl.lastPathComponent)
                
                try! FileManager.default.copyItem(at: fileUrl, to: destinationUrl)
            }
        }
    }
    
    public init(rootFolderUrl: URL) {
        self.rootFolderUrl = rootFolderUrl
        JournalFileManager.ensureLocalsAndRemotesDirectoriesExist(url: rootFolderUrl)
    }
    
    public func save(to newRootFolderUrl: URL) {
        print("Save called to \"\(newRootFolderUrl.path)\"")
        if newRootFolderUrl != self.rootFolderUrl {
            let oldRootFolderUrl = self.rootFolderUrl
            
            // Close old file writers and copy to new folder location
            localWriters.forEach { identifier, localWriter in
                localWriter.close()
            }
            
            JournalFileManager.ensureLocalsAndRemotesDirectoriesExist(url: newRootFolderUrl)
            
            let oldLocalsFolder = oldRootFolderUrl.appendingPathComponent("locals")
            let oldRemotesFolder = oldRootFolderUrl.appendingPathComponent("remotes")
            let newLocalsFolder = newRootFolderUrl.appendingPathComponent("locals")
            let newRemotesFolder = newRootFolderUrl.appendingPathComponent("remotes")

            JournalFileManager.copyFiles(from: oldLocalsFolder, to: newLocalsFolder)
            JournalFileManager.copyFiles(from: oldRemotesFolder, to: newRemotesFolder)
            
            self.rootFolderUrl = newRootFolderUrl
            self.localWriters = [:] // Next time we write a local diff, localWriter will be re-created
            self.remoteReaders = [:]
        }
    }
    
    public func writeLocal(diffs: [ObjectDiff], to identifier: String) {
        if let localWriter = localWriters[identifier] {
            localWriter.append(diffs: diffs)
        } else {
            let localsFolder = rootFolderUrl.appendingPathComponent("locals")
            let fileUrl = localsFolder.appendingPathComponent("\(identifier).journal")
            if let localWriter = try? JournalFileWriter(url: fileUrl) {
                localWriters[identifier] = localWriter
                localWriter.append(diffs: diffs)
            } else {
                assertionFailure()
            }
        }
    }
    
    public func localFileUrl(for identifier: String) -> URL? {
        let fileUrl = rootFolderUrl.appendingPathComponent("locals/\(identifier).journal")
        if FileManager.default.fileExists(atPath: fileUrl.path) {
            return fileUrl
        } else {
            return nil
        }
    }
    
    public func replaceRemoteJournalFile(identifier: String, with url: URL, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .background).async {
            let destinationUrl = self.rootFolderUrl.appendingPathComponent("remotes/\(identifier).journal")
            try! FileManager.default.copyItem(at: url, to: destinationUrl)
            
            completion()
        }
    }
    
    public func readNextDiffs(from identifier: String, byteOffset: UInt64, maxDiffs: Int) -> JournalReadResult {
        if let remoteReader = remoteReaders[identifier] {
            return remoteReader.readNextDiffs(byteOffset: byteOffset, maxDiffs: maxDiffs)
        } else {
            let remotesFolder = rootFolderUrl.appendingPathComponent("remotes")
            let fileUrl = remotesFolder.appendingPathComponent("\(identifier).journal")
            if let remoteReader = try? JournalFileReader(url: fileUrl) {
                remoteReaders[identifier] = remoteReader
                return remoteReader.readNextDiffs(byteOffset: byteOffset, maxDiffs: maxDiffs)
            } else {
                assertionFailure()
                return JournalReadResult(diffs: [], byteOffset: 0)
            }
        }
    }
}
