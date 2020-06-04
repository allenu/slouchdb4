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
//    - when writeLocal(commands:,to:) is called, destination stream is created/opened if not
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
    // See DESIGN.md for details on working folder vs storage folder
    public let workingFolderUrl: URL
    public var storageFolderUrl: URL?
    
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
                
                // Remove file first before overwriting
                if FileManager.default.fileExists(atPath: destinationUrl.path) {
                    try! FileManager.default.removeItem(at: destinationUrl)
                }
                
                try! FileManager.default.copyItem(at: fileUrl, to: destinationUrl)
            }
        }
    }
    
    public init(workingFolderUrl: URL, storageFolderUrl: URL? = nil) {
        self.workingFolderUrl = workingFolderUrl
        self.storageFolderUrl = storageFolderUrl
        JournalFileManager.ensureLocalsAndRemotesDirectoriesExist(url: workingFolderUrl)
        
        if let storageFolderUrl = storageFolderUrl {
            assert(storageFolderUrl != workingFolderUrl)
            
            // Make sure to copy local journals over to the working folder so that we're ready to append.
            // TODO: Maybe only copy on first write to the command?
        }
    }
    
    public func save(to newStorageFolderUrl: URL) {
        print("Save called to \"\(newStorageFolderUrl.path)\"")
        
        JournalFileManager.ensureLocalsAndRemotesDirectoriesExist(url: newStorageFolderUrl)
        
        // We're about to save. Three scenarios can occur:
        //
        // 1. We only have a working folder AND we're saving to the working folder
        //    => No need to do anything because our edits are already happening live in that folder.
        //
        // 2. We only have a working folder AND we don't have a local storage folder yet AND
        //    we're saving to a different folder from the working folder. This means we are
        //    creating a new storage folder where persistent data will go. We will keep the working
        //    folder around, and then
        //    => need to copy all of the working folder contents to the new storage folder
        //    => set our storage folder to this new storage folder location
        //    => reset file readers in case they pointed to the old files
        //
        // 3. We have a working folder AND a local storage folder AND we're saving to the same
        //    storage folder location as before.
        //    => need to copy all of the contents of working folder into the storage folder
        //    => reset file readers in case they pointed to the old files
        //
        // 4. We have a working folder AND a local storage folder AND we're saving to a NEW
        //    storage folder from before.
        //    => copy all contents of old storage folder to new one (but skip any files that
        //       are newly updated in the working folder)
        //    => copy contents of working folder into storage folder
        //    => set our storage folder to this new storage folder location
        //    => reset file readers in case they pointed to the old files
        
        let closeAllReaders = {
            self.remoteReaders.forEach { identifier, reader in
                reader.close()
            }
        }
        
        if let storageFolderUrl = storageFolderUrl {
            if newStorageFolderUrl == storageFolderUrl {
                // Scenario 3: We're saving to the existing storage folder
                
                let workingFolderLocals = workingFolderUrl.appendingPathComponent("locals")
                let workingFolderRemotes = workingFolderUrl.appendingPathComponent("remotes")
                let newStorageLocals = newStorageFolderUrl.appendingPathComponent("locals")
                let newStorageRemotes = newStorageFolderUrl.appendingPathComponent("remotes")
                
                JournalFileManager.copyFiles(from: workingFolderLocals, to: newStorageLocals)
                JournalFileManager.copyFiles(from: workingFolderRemotes, to: newStorageRemotes)
                closeAllReaders()
                self.remoteReaders = [:]
            } else {
                // Scenario 4: We're saving to a new storage folder but used a different one before
                let oldStorageLocals = storageFolderUrl.appendingPathComponent("locals")
                let oldStorageRemotes = storageFolderUrl.appendingPathComponent("remotes")
                let workingFolderLocals = workingFolderUrl.appendingPathComponent("locals")
                let workingFolderRemotes = workingFolderUrl.appendingPathComponent("remotes")
                let newStorageLocals = newStorageFolderUrl.appendingPathComponent("locals")
                let newStorageRemotes = newStorageFolderUrl.appendingPathComponent("remotes")

                // Copy files from old storage first
                JournalFileManager.copyFiles(from: oldStorageLocals, to: newStorageLocals)
                JournalFileManager.copyFiles(from: oldStorageRemotes, to: newStorageRemotes)

                // Then potentially overwrite them with newer files from working folder
                JournalFileManager.copyFiles(from: workingFolderLocals, to: newStorageLocals)
                JournalFileManager.copyFiles(from: workingFolderRemotes, to: newStorageRemotes)

                // This line may not be necessary since the storage folder may be a temporary
                // location that could get deleted.
//                self.storageFolderUrl = newStorageFolderUrl
                closeAllReaders()
                self.remoteReaders = [:]
            }
        } else {
            if newStorageFolderUrl == workingFolderUrl {
                // Scenario 1: We're just using a working folder, so no action is required
            } else {
                // Scenario 2: We're saving to a new storage folder
                
                let workingFolderLocals = workingFolderUrl.appendingPathComponent("locals")
                let workingFolderRemotes = workingFolderUrl.appendingPathComponent("remotes")
                let newStorageLocals = newStorageFolderUrl.appendingPathComponent("locals")
                let newStorageRemotes = newStorageFolderUrl.appendingPathComponent("remotes")

                JournalFileManager.copyFiles(from: workingFolderLocals, to: newStorageLocals)
                JournalFileManager.copyFiles(from: workingFolderRemotes, to: newStorageRemotes)
                // This line may not be necessary since the storage folder may be a temporary
                // location that could get deleted.
//                self.storageFolderUrl = newStorageFolderUrl
                closeAllReaders()
                self.remoteReaders = [:]
            }
        }
    }
    
    public func writeLocal(commands: [Command], to identifier: String) {
        if let localWriter = localWriters[identifier] {
            localWriter.append(commands: commands)
        } else {
            let localsFolder = workingFolderUrl.appendingPathComponent("locals")
            let workingFolderFileUrl = localsFolder.appendingPathComponent("\(identifier).journal")

            // Before opening local journal to write to, see if file exists in storage first,
            // in which case copy to working folder first if working folder version doesn't
            // exist yet.
            if let storageFolderUrl = storageFolderUrl {
                let storageFolderFileUrl = storageFolderUrl.appendingPathComponent("locals/\(identifier).journal")
                if FileManager.default.fileExists(atPath: storageFolderFileUrl.path) &&
                    !FileManager.default.fileExists(atPath: workingFolderFileUrl.path) {
                    // Working folder files doesn't exist yet, but storage one does, so
                    // we'll need to copy to the working folder so we are appending to
                    // it.
                    
                    try! FileManager.default.copyItem(at: storageFolderFileUrl, to: workingFolderFileUrl)
                }
            }
            
            // Now open the file
            if let localWriter = try? JournalFileWriter(url: workingFolderFileUrl) {
                localWriters[identifier] = localWriter
                localWriter.append(commands: commands)
            } else {
                assertionFailure()
            }
        }
    }
    
    public func localFileUrl(for identifier: String) -> URL? {
        let fileUrl = workingFolderUrl.appendingPathComponent("locals/\(identifier).journal")
        if FileManager.default.fileExists(atPath: fileUrl.path) {
            return fileUrl
        } else {
            // Try storage folder next if it's not in working folder
            if let storageFolderUrl = storageFolderUrl {
                let storageFileUrl = storageFolderUrl.appendingPathComponent("locals/\(identifier).journal")
                if FileManager.default.fileExists(atPath: fileUrl.path) {
                    return storageFileUrl
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
    }
    
    public func replaceRemoteJournalFile(identifier: String, with url: URL, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .background).async {
            
            // Before deleting file, re-open the read stream by removing it. It'll get re-opened on next read.
            if let existingRemoteReader = self.remoteReaders[identifier] {
                // existingRemoteReader.close()
                self.remoteReaders.removeValue(forKey: identifier)
            }

            let destinationUrl = self.workingFolderUrl.appendingPathComponent("remotes/\(identifier).journal")
            if FileManager.default.fileExists(atPath: destinationUrl.path) {
                try! FileManager.default.removeItem(at: destinationUrl)
            }
            try! FileManager.default.copyItem(at: url, to: destinationUrl)
            
            completion()
        }
    }
    
    public func readNextCommands(from identifier: String, byteOffset: UInt64, maxCommands: Int) -> JournalReadResult {
        if let remoteReader = remoteReaders[identifier] {
            return remoteReader.readNextCommands(byteOffset: byteOffset, maxCommands: maxCommands)
        } else {
            let workingRemotesFolder = workingFolderUrl.appendingPathComponent("remotes")
            
            // See if file exists to read in working folder
            let workingRemotesFileUrl = workingRemotesFolder.appendingPathComponent("\(identifier).journal")
            
            let fileUrl: URL?
            if FileManager.default.fileExists(atPath: workingRemotesFileUrl.path) {
                fileUrl = workingRemotesFileUrl
            } else if let storageRemotesFolder = storageFolderUrl?.appendingPathComponent("remotes") {
                // Try the storage remotes folder next, if it exists
                let storageRemotesFileUrl = storageRemotesFolder.appendingPathComponent("\(identifier).journal")
                if FileManager.default.fileExists(atPath: storageRemotesFileUrl.path) {
                    fileUrl = storageRemotesFileUrl
                } else {
                    fileUrl = nil
                }
            } else {
                fileUrl = nil
            }

            if let fileUrl = fileUrl,
                let remoteReader = try? JournalFileReader(url: fileUrl) {
                
                remoteReaders[identifier] = remoteReader
                return remoteReader.readNextCommands(byteOffset: byteOffset, maxCommands: maxCommands)
            } else {
                // File does not exist in working folder. Error !
//                assertionFailure()
                return JournalReadResult(commands: [], byteOffset: 0)
            }
        }
    }
}
