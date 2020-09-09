//
//  JournalManager.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/25/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//
//  What does a JournalManager do? It manages this knowledge:
//  - what our local device identifier is
//  - the last version of our remotes we pushed up to the remote
//  - which remote journal files we have and which version they are
//  - where we are in reading those journal files (the byte offset within the file)
//
//  Clients can ask the journal manager to get the latest commands. What this does is load
//  the given journal file requested and starts reading data from it at the last read index.
//  This ensures we don't load the entire file into memory.
//
//  JournalManager is also responsible for talking to the remoteFileStore to push any local
//  files to the remote and to pull any remote files to local.

import Foundation

public protocol JournalFileManaging {
    var remotesFolder: URL { get }
    
    func save(to rootFolderUrl: URL)
    
    func writeLocal(commands: [Command], to identifier: String)
    
    func sizeOfFile(for identifier: String) -> UInt64?
    
    // Get the url for a local journal file (searches only in /local/)
    func localFileUrl(for identifier: String) -> URL?

    // We have a newer version of a remote journal file, so replace the file contents with the new one and
    // call completion when done copying.
    func replaceRemoteJournalFile(identifier: String, with url: URL, completion: @escaping () -> Void)
    
    func readNextCommands(from identifier: String, byteOffset: UInt64, maxCommands: Int) -> JournalReadResult
}

public protocol JournalManagerStateStoring {
    func localIdentifier() -> String
    func allLocalIdentifiers() -> [String]
    
    // Offsets into each journal that we've processed... Note that this excludes the local
    // journal. Local journal data is automatically processed as it comes in.
    func journalByteOffset(identifier: String) -> UInt64?
    func updateJournal(identifier: String, byteOffset: UInt64)
    func allJournalByteOffsets() -> [String : UInt64]
    
    // Info about the versions of the remote journals.
    func remoteFileVersion(identifier: String) -> String?
    func updateRemoteJournal(identifier: String, fileVersion: String)
    func allRemoteFileVersions() -> [String : String]
    
    // Info about which version of the local journal(s) we have pushed up last.
    func lastVersionPushed(identifier: String) -> String?
    func updateLocalJournal(identifier: String, lastVersionPushed: String)
    
    // Reset all byte offsets and remote versions (to unknown) and pushed versions to none.
    // This forces us to resync everything on next sync.
    func resetSyncState()
}

public struct JournalManagerStoredState: Codable {
    public let localIdentifier: String
    public let journalByteOffsets: [String : UInt64]
    public let remoteFileVersion: [String : String]
    public let lastLocalVersionPushed: String
    
    public init(localIdentifier: String,
                journalByteOffsets: [String : UInt64],
                remoteFileVersion: [String : String],
                lastLocalVersionPushed: String) {
        self.localIdentifier = localIdentifier
        self.journalByteOffsets = journalByteOffsets
        self.remoteFileVersion = remoteFileVersion
        self.lastLocalVersionPushed = lastLocalVersionPushed
    }
}

// Fetch all those files that differ from local version, excluding a known list.
public func findNewerRemoteFiles(excludedFiles: [String], localFileVersions: [String : String], remoteFileVersions: [String : String]) -> [String] {
    let filesToFetch: [String] = remoteFileVersions.filter( { identifier, remoteVersion in
        let isExcludedFile = excludedFiles.contains(identifier)
        guard !isExcludedFile else { return false }

        let localFileVersion = localFileVersions[identifier] ?? "not-found"
        let shouldFetchFile = localFileVersion != remoteVersion
        return shouldFetchFile
    }).map { $0.key }
    
    return filesToFetch
}

public class JournalManager: JournalManaging {
    let maxCommands: Int = 1000
    
    public weak var remoteFileStore: RemoteFileStoring?
    var journalFileManager: JournalFileManaging
    let stateStore: JournalManagerStateStoring

    // --------------------------------------
    // State data -- should come from storage
    // --------------------------------------
    public var localIdentifier: String {
        return stateStore.localIdentifier()
    }
    
    // When sync begins, record where journal byte offsets are so that we can
    // track progress as we process commands.
    var journalByteOffsetsAtSyncStart: [String : UInt64]?

    public init(stateStore: JournalManagerStateStoring,
                journalFileManager: JournalFileManaging) {
        self.stateStore = stateStore
        self.journalFileManager = journalFileManager
        
        detectRemotes()
    }
    
    public func save(to folderUrl: URL) {
        // Save data to StoredState
        
        // Make note of folder now that we're saving
        self.journalFileManager.save(to: folderUrl)
    }
    
    public func addToLocalJournal(command: Command) {
        // Clear last version pushed to indicate that we need to re-push
        stateStore.updateLocalJournal(identifier: localIdentifier, lastVersionPushed: "version-is-dirty")

        journalFileManager.writeLocal(commands: [command], to: localIdentifier)
    }
    
    // Detect any remotes that aren't known
    public func detectRemotes() {
        let remotesFolder = journalFileManager.remotesFolder
        
        let fileEnumerator = FileManager.default.enumerator(at: remotesFolder, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
        fileEnumerator?.skipDescendants()
        
        while let element = fileEnumerator?.nextObject() {
            if let fileURL = element as? URL {
                if fileURL.lastPathComponent.hasSuffix(".journal" ) {
                    let journalIdentifier = fileURL.lastPathComponent.replacingOccurrences(of: ".journal", with: "")
                    
                    // No byte offset, so we should store that this exists.
                    if stateStore.journalByteOffset(identifier: journalIdentifier) == nil {
                        stateStore.updateJournal(identifier: journalIdentifier, byteOffset: 0)
                    }
                }
            }
        }

    }
    
    func syncFiles(completion: @escaping (SyncFilesResponse) -> Void) {
        guard let remoteFileStore = remoteFileStore else { return }
        
        let doFetchRemoteFiles: ([String : String]) -> Void = { [weak self] fetchedVersions in
            guard let strongSelf = self else { return }
            
            let knownRemoteFileVersions: [String : String] = strongSelf.stateStore.allRemoteFileVersions()
            
            // Fetch all those files that differ from local version
            let filesToFetch = findNewerRemoteFiles(excludedFiles: strongSelf.stateStore.allLocalIdentifiers(),
                                                    localFileVersions: knownRemoteFileVersions,
                                                    remoteFileVersions: fetchedVersions)
            
//            print("syncFiles fetching \(filesToFetch)")
            
            if filesToFetch.count > 0 {
                remoteFileStore.fetchFiles(identifiers: filesToFetch) { [weak self] response in
                    guard let strongSelf = self else { return }
                    
//                    print("fetched result: \(response)")
                    
                    switch response {
                    case .success(let filesAndVersions):
                        assert(filesAndVersions.count == filesToFetch.count)
                        
                        // Do file replace in background queue
                        DispatchQueue.global(qos: .background).async {
                            let updatedFiles: [String] = filesAndVersions.map { $0.url.lastPathComponent }
                            
                            let dispatchGroup = DispatchGroup()
                            
                            filesAndVersions.forEach { fileAndVersion in
                                let remoteFileUrl = fileAndVersion.url
                                let fileIdentifier = remoteFileUrl.lastPathComponent.replacingOccurrences(of: ".journal", with: "")
                                strongSelf.stateStore.updateRemoteJournal(identifier: fileIdentifier, fileVersion: fileAndVersion.version)
                                
                                dispatchGroup.enter()
                                
                                // Replace the remote journal file and when done update the state of this journal entry
                                strongSelf
                                    .journalFileManager
                                    .replaceRemoteJournalFile(identifier: fileIdentifier, with: remoteFileUrl, completion: {
                                        
//                                        print("replaced file \(fileIdentifier) with \(remoteFileUrl)")

                                        DispatchQueue.main.async {
                                            // Add journal readers for each journal that we're missing
                                            if strongSelf.stateStore.journalByteOffset(identifier: fileIdentifier) == nil {
                                                // Add new entry since it wasn't there yet
                                                strongSelf.stateStore.updateJournal(identifier: fileIdentifier, byteOffset: 0)
                                            }
                                            
                                            dispatchGroup.leave()
                                        }
                                })
                            }
                            
                            // Wait for all journal replacement requests to finish before calling completion
                            dispatchGroup.notify(queue: .main) {
                                completion(.success(updatedFiles: updatedFiles))
                            }
                        }
                        
                    case .failure(let reason):
                        let fetchRemoteFilesFailedReason: SyncFilesFailureReason
                        switch reason {
                            // TODO: convert reason to a SyncFilesFailureReason type
                        default:
                            fetchRemoteFilesFailedReason = .fetchRemoteFilesFailed
                        }
                         
                        DispatchQueue.main.async {
                            completion(.failure(reason: fetchRemoteFilesFailedReason))
                        }
                    }
                }
            } else {
                // No files to sync!
                DispatchQueue.main.async {
                    // No results
                    // TODO: have .successNoChange ?
                    completion(.success(updatedFiles: []))
                }
            }
        }
        
        DispatchQueue.global(qos: .background).async {
            remoteFileStore.fetchRemoteFileVersions(completionHandler: { [weak self] fetchedRemoteFileVersionsResponse in
                guard let strongSelf = self else { return }
                
                print("fetchedRemoteFileVersions: \(fetchedRemoteFileVersionsResponse)")
                
                switch fetchedRemoteFileVersionsResponse {
                case .success(let fetchedVersions):
                    
                    var shouldPushLocalFile = false
                    if let remoteVersionOfLocalJournal = fetchedVersions[strongSelf.localIdentifier] {
                        let lastLocalVersionPushed = strongSelf.stateStore.lastVersionPushed(identifier: strongSelf.localIdentifier)
                        shouldPushLocalFile = lastLocalVersionPushed != remoteVersionOfLocalJournal
                    } else {
                        shouldPushLocalFile = true
                    }
                    
                    if shouldPushLocalFile {
                        // Get the URL of the local journal
                        if let localFileUrl = strongSelf.journalFileManager.localFileUrl(for: strongSelf.localIdentifier) {
                            remoteFileStore.push(localFile: localFileUrl) { [weak self] pushResponse in
                                guard let strongSelf = self else { return }
                                
                                switch pushResponse {
                                case .success(let version):
                                    // Push succeeded.
                                    strongSelf.stateStore.updateLocalJournal(identifier: strongSelf.localIdentifier, lastVersionPushed: version)
                                    
                                    doFetchRemoteFiles(fetchedVersions)
                                    
                                case .failure(let reason):
                                    // TODO: Convert reason to a more specific sync files failure reason
                                    _ = reason
                                    completion(.failure(reason: .pushFailed))
                                }
                            }
                        } else {
                            // Maybe there wasn't a local file to push, so skip it
                            
                            doFetchRemoteFiles(fetchedVersions)
                        }
                    } else {
                        // No files to push, so treat as success and go onto next step
                        doFetchRemoteFiles(fetchedVersions)
                    }
                    
                case .failure(let reason):
                    // TODO: Convert reason to a more specific sync files failure reason
                    _ = reason
                    DispatchQueue.main.async {
                        completion(.failure(reason: .fetchRemoteVersionsFailed))
                    }
                }
            })
        }
    }
    
    // The job of this function is to grab as many commands (at most maxCommands) from the journals that have pending
    // commands that we have not yet processed.
    //
    // We keep track of a byte offset within a journal and if the journal gets updated with new data, we can
    // try to fetch from it and update the byte offset if we do get more data from it.
    //
    // We go through each journal in our list, one at a time, grabbing commands. If we exhaust all the commands in
    // a single journal and still have room for more commands, we go onto the next journal in the list (arbitrarily
    // ordered by the journalByteOffsets dictionary) and try to get more commands from that.
    //
    // If we find there are no more commands outstanding, then we return before filling up the commands with max content.
    func fetchLatestCommandsWithoutSync(completion: @escaping (FetchJournalCommandsResponse, CallbackWhenCommandsMerged?) -> Void) {
        // Go through journals getting up to maxCommands until there are no more changes
        // or we reach maxCommands.
        
        var commands: [Command] = []
        var journalsHaveNoMoreChanges = false
        var journalByteOffsetsToUpdateAfterMerge: [String : UInt64] = [:]
        
        let journalByteOffsets = stateStore.allJournalByteOffsets()
        
        var fileSizes: [String : UInt64] = [:]
        journalByteOffsets.keys.forEach { identifier in
            if let fileSize = self.journalFileManager.sizeOfFile(for: identifier) {
                fileSizes[identifier] = fileSize
            }
        }
        
        while !journalsHaveNoMoreChanges {
            // Find a journal that has changes and consume as much as possible
            
            var loadedJournalChanges = false
            journalByteOffsets.forEach { identifier, byteOffset in
                
                // Try to use journalByteOffsetsToUpdateAfterMerge entry if available as it has
                // our updated pointer in it. journalByteOffsets won't be updated until we commit
                // the change.
                let updatedByteOffset = journalByteOffsetsToUpdateAfterMerge[identifier] ?? byteOffset
                
                if commands.count >= maxCommands {
                    // Do nothing. We have enough commands.
                } else {
                    // Try to get changes from this journal, a max of N
                    let maxCommandsAttemptToFetch = maxCommands - commands.count
                    
                    let readResult = self.journalFileManager.readNextCommands(from: identifier,
                                                                           byteOffset: updatedByteOffset,
                                                                           maxCommands: maxCommandsAttemptToFetch)
                    
//                    print("readNextCommands from: \(identifier) byteOffset: \(updatedByteOffset) => \(readResult.commands.count) commands  \(readResult.byteOffset) offset")
                    
                    if readResult.commands.count > 0 {
                        commands.append(contentsOf: readResult.commands)
                        loadedJournalChanges = true
                        
                        journalByteOffsetsToUpdateAfterMerge[identifier] = readResult.byteOffset
                    } else {
                        // No commands to get ... keep going
                    }
                }
            }
            
            journalsHaveNoMoreChanges = !loadedJournalChanges
        }
        
        // Compute our progress so far
        var totalBytesProcessed: UInt64 = 0
        var totalBytes: UInt64 = 0
        if let journalByteOffsetsAtSyncStart = journalByteOffsetsAtSyncStart {
            journalByteOffsetsAtSyncStart.forEach { identifier, startByteOffset in
                let fileSize = fileSizes[identifier] ?? 0
                totalBytes = totalBytes + fileSize
                
                let currentBytesOffset = journalByteOffsetsToUpdateAfterMerge[identifier] ?? journalByteOffsets[identifier] ?? 0
                let bytesProcessed = currentBytesOffset - startByteOffset
                
                totalBytesProcessed = totalBytesProcessed + bytesProcessed
            }
        }
        let percent: Double
        if totalBytes > 0 {
            percent = Double(totalBytesProcessed) / Double(totalBytes)
        } else {
            percent = 0.0
        }

        DispatchQueue.main.async {
            let successType: FetchJournalSuccessType
            if commands.count == self.maxCommands {
                // Assume there may be more results
                successType = .partialResults(commands: commands, percent: percent)
            } else {
                successType = .results(commands: commands)
            }

            // Client calls this when it's done processing the successful list of commands
            let callbackWhenCommandsMerged: CallbackWhenCommandsMerged = { [weak self] success in
                guard let strongSelf = self else { return }
                
                if success {
                    // We successfully merged the changes, so now we are safe to update byte offsets
                    journalByteOffsetsToUpdateAfterMerge.forEach { identifier, byteOffset in
                        strongSelf.stateStore.updateJournal(identifier: identifier, byteOffset: byteOffset)
                    }
                } else {
                    assertionFailure("What do we even do here if merging fails? Is it even possible?")
                }
            }
            
            completion(FetchJournalCommandsResponse.success(type: successType), callbackWhenCommandsMerged)
        }
    }
    
    public func fetchLatestCommands(skipRemoteFetch: Bool = false, completion: @escaping (FetchJournalCommandsResponse, CallbackWhenCommandsMerged?) -> Void) {
        if !skipRemoteFetch {
            syncFiles(completion: { [weak self] syncFilesResponse in
                guard let strongSelf = self else { return }
                
                switch syncFilesResponse {
                case .success(let updatedFiles):
                    // TODO: See if really care about the updatedFiles when we sync and try to do a fetchLatestCommandsWithoutSync()
                    _ = updatedFiles
                    
                    if updatedFiles.count > 0 || strongSelf.journalByteOffsetsAtSyncStart == nil {
                        // We just sync'ed, so record all byte offsets now before we start fetching commands
                        strongSelf.journalByteOffsetsAtSyncStart = strongSelf.stateStore.allJournalByteOffsets()
                    }
                    
                    strongSelf.fetchLatestCommandsWithoutSync(completion: completion)
                    
                case .failure:
                    DispatchQueue.main.async {
                        completion(.failure, nil)
                    }
                }
            })
        } else {
            if journalByteOffsetsAtSyncStart == nil {
                // We just sync'ed, so record all byte offsets now before we start fetching commands
                journalByteOffsetsAtSyncStart = stateStore.allJournalByteOffsets()
            }

            fetchLatestCommandsWithoutSync(completion: completion)
        }
    }
    
    public func resetSyncState() {
        stateStore.resetSyncState()
    }
}
