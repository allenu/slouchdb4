//
//  JournalManager.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/25/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public protocol JournalFileManaging {
    func save(to rootFolderUrl: URL)
    
    func writeLocal(diffs: [ObjectDiff], to identifier: String)
    
    // Get the url for a local journal file (searches only in /local/)
    func localFileUrl(for identifier: String) -> URL?

    // We have a newer version of a remote journal file, so replace the file contents with the new one and
    // call completion when done copying.
    func replaceRemoteJournalFile(identifier: String, with url: URL, completion: @escaping () -> Void)
    
    func readNextDiffs(from identifier: String, byteOffset: UInt64, maxDiffs: Int) -> JournalReadResult
}

public struct JournalManagerStoredState: Codable {
    let localIdentifier: String
    let journalByteOffsets: [String : UInt64]
    let remoteFileVersion: [String : String]
    let lastLocalVersionPushed: String
    
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
    let maxDiffs: Int = 100
    
    let remoteFileStore: RemoteFileStoring
    var journalFileManager: JournalFileManaging

    // --------------------------------------
    // State data -- should come from storage
    // --------------------------------------
    public var localIdentifier: String
    var journalByteOffsets: [String : UInt64]
    
    // Key is the lastPathComponent of the file. However, the lastPathComponent of
    // a journal file is just the guid, so no to worry about file extensions.
    var remoteFileVersion: [String : String]
    
    // TODO: Make it possible to rotate through local identifiers
    var lastLocalVersionPushed: String
    
    var shouldSync: Bool {
        // TODO: Logic to see if we should sync remotes
        // Some potential rules:
        // - we do have a remote setup properly
        // - we have internet access
        // - enough time has elapsed since last sync
        return true
    }

    public init(journalFileManager: JournalFileManaging, remoteFileStore: RemoteFileStoring, storedState: JournalManagerStoredState) {
        self.journalFileManager = journalFileManager
        self.remoteFileStore = remoteFileStore

        self.localIdentifier = storedState.localIdentifier
        self.journalByteOffsets = storedState.journalByteOffsets
        self.lastLocalVersionPushed = storedState.lastLocalVersionPushed
        self.remoteFileVersion = storedState.remoteFileVersion
    }
    
    public static func create(from folderUrl: URL, with remoteFileStore: RemoteFileStoring) -> JournalManager? {
        let fileUrl = folderUrl.appendingPathComponent("journal-state.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        if let data = try? Data(contentsOf: fileUrl),
            let storedState = try? decoder.decode(JournalManagerStoredState.self, from: data) {
            
            let directory = NSTemporaryDirectory()
            let subpath = UUID().uuidString
            let tempUrl = NSURL.fileURL(withPathComponents: [directory, subpath])!
            let journalManager = JournalManager(journalFileManager: JournalFileManager(workingFolderUrl: tempUrl, storageFolderUrl:  folderUrl), remoteFileStore: remoteFileStore, storedState: storedState)
            
            return journalManager
        }
        
        return nil
    }
    
    public func save(to folderUrl: URL) {
        // Save data to StoredState
        
        // Make note of folder now that we're saving
        self.journalFileManager.save(to: folderUrl)
        
        let storedState = JournalManagerStoredState(localIdentifier: localIdentifier,
                                                    journalByteOffsets: journalByteOffsets,
                                                    remoteFileVersion: remoteFileVersion,
                                                    lastLocalVersionPushed: lastLocalVersionPushed)
        let fileUrl = folderUrl.appendingPathComponent("journal-state.json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            
            let data = try encoder.encode(storedState)
            try data.write(to: fileUrl)
        } catch {
            print("Error saving to \(fileUrl)")
        }
        
    }
    
    public func addToLocalJournal(diff: ObjectDiff) {
        // Clear last version pushed to indicate that we need to re-push
        lastLocalVersionPushed = "version-is-dirty"
        journalFileManager.writeLocal(diffs: [diff], to: localIdentifier)
    }
    
    func syncFiles(completion: @escaping (SyncFilesResponse) -> Void) {
        let doFetchRemoteFiles: ([String : String]) -> Void = { [weak self] fetchedVersions in
            guard let strongSelf = self else { return }
            
            // Fetch all those files that differ from local version
            let filesToFetch = findNewerRemoteFiles(excludedFiles: [strongSelf.localIdentifier],
                                                    localFileVersions: strongSelf.remoteFileVersion,
                                                    remoteFileVersions: fetchedVersions)
            
            if filesToFetch.count > 0 {
                strongSelf.remoteFileStore.fetchFiles(identifiers: filesToFetch) { [weak self] response in
                    guard let strongSelf = self else { return }
                    
                    switch response {
                    case .success(let fileAndVersion):
                        assert(fileAndVersion.count == filesToFetch.count)
                        
                        // Do file replace in background queue
                        DispatchQueue.global(qos: .background).async {
                            let updatedFiles: [String] = fileAndVersion.map { $0.url.lastPathComponent }
                            
                            let dispatchGroup = DispatchGroup()
                            
                            fileAndVersion.forEach { fileAndVersion in
                                let remoteFileUrl = fileAndVersion.url
                                let fileIdentifier = remoteFileUrl.lastPathComponent.replacingOccurrences(of: ".journal", with: "")
                                strongSelf.remoteFileVersion[fileIdentifier] = fileAndVersion.version
                                
                                dispatchGroup.enter()
                                
                                // Replace the remote journal file and when done update the state of this journal entry
                                strongSelf
                                    .journalFileManager
                                    .replaceRemoteJournalFile(identifier: fileIdentifier, with: remoteFileUrl, completion: {
                                        
                                        print("replaced file \(fileIdentifier) with \(remoteFileUrl)")

                                        // Add journal readers for each journal that we're missing
                                        if strongSelf.journalByteOffsets[fileIdentifier] == nil {
                                            // Add new entry since it wasn't there yet
                                            strongSelf.journalByteOffsets[fileIdentifier] = 0
                                        }
                                        
                                        dispatchGroup.leave()
                                })
                            }
                            
                            // Wait for all journal replacement requests to finish before calling completion
                            dispatchGroup.wait()
                            
                            DispatchQueue.main.async {
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
            self.remoteFileStore.fetchRemoteFileVersions(completionHandler: { [weak self] fetchedRemoteFileVersionsResponse in
                guard let strongSelf = self else { return }
                
                switch fetchedRemoteFileVersionsResponse {
                case .success(let fetchedVersions):
                    
                    var shouldPushLocalFile = false
                    if let remoteVersionOfLocalJournal = fetchedVersions[strongSelf.localIdentifier] {
                        shouldPushLocalFile = strongSelf.lastLocalVersionPushed != remoteVersionOfLocalJournal
                    } else {
                        shouldPushLocalFile = true
                    }
                    
                    if shouldPushLocalFile {
                        // Get the URL of the local journal
                        if let localFileUrl = strongSelf.journalFileManager.localFileUrl(for: strongSelf.localIdentifier) {
                            strongSelf.remoteFileStore.push(localFile: localFileUrl) { [weak self] pushResponse in
                                guard let strongSelf = self else { return }
                                
                                switch pushResponse {
                                case .success(let version):
                                    // Push succeeded.
                                    strongSelf.lastLocalVersionPushed = version
                                    
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
    
    // The job of this function is to grab as many diffs (at most maxDiffs) from the journals that have pending
    // diffs that we have not yet processed.
    //
    // We keep track of a byte offset within a journal and if the journal gets updated with new data, we can
    // try to fetch from it and update the byte offset if we do get more data from it.
    //
    // We go through each journal in our list, one at a time, grabbing diffs. If we exhaust all the diffs in
    // a single journal and still have room for more diffs, we go onto the next journal in the list (arbitrarily
    // ordered by the journalByteOffsets dictionary) and try to get more diffs from that.
    //
    // If we find there are no more diffs outstanding, then we return before filling up the diffs with max content.
    func fetchLatestDiffsWithoutSync(completion: @escaping (FetchJournalDiffsResponse, CallbackWhenDiffsMerged?) -> Void) {
        // Go through journals getting up to maxDiffs until there are no more changes
        // or we reach maxDiffs.
        
        var diffs: [ObjectDiff] = []
        var journalsHaveNoMoreChanges = false
        var journalByteOffsetsToUpdateAfterMerge: [String : UInt64] = [:]
        
        while !journalsHaveNoMoreChanges {
            // Find a journal that has changes and consume as much as possible
            
            var loadedJournalChanges = false
            journalByteOffsets.forEach { identifier, byteOffset in
                
                // Try to use journalByteOffsetsToUpdateAfterMerge entry if available as it has
                // our updated pointer in it. journalByteOffsets won't be updated until we commit
                // the change.
                let updatedByteOffset = journalByteOffsetsToUpdateAfterMerge[identifier] ?? byteOffset
                
                if diffs.count >= maxDiffs {
                    // Do nothing. We have enough diffs.
                } else {
                    // Try to get changes from this journal, a max of N
                    let maxDiffsAttemptToFetch = maxDiffs - diffs.count
                    
                    let readResult = self.journalFileManager.readNextDiffs(from: identifier,
                                                                           byteOffset: updatedByteOffset,
                                                                           maxDiffs: maxDiffsAttemptToFetch)
                    
                    print("readNextDiffs from: \(identifier) byteOffset: \(updatedByteOffset) => \(readResult.diffs.count) diffs  \(readResult.byteOffset) offset")
                    
                    if readResult.diffs.count > 0 {
                        diffs.append(contentsOf: readResult.diffs)
                        loadedJournalChanges = true
                        
                        journalByteOffsetsToUpdateAfterMerge[identifier] = readResult.byteOffset
                    } else {
                        // No diffs to get ... keep going
                    }
                }
            }
            
            journalsHaveNoMoreChanges = !loadedJournalChanges
        }
        
        DispatchQueue.main.async {
            let successType: FetchJournalSuccessType
            if diffs.count == self.maxDiffs {
                // Assume there may be more results
                successType = .partialResults(diffs: diffs, percent: 0.25)
            } else {
                successType = .results(diffs: diffs)
            }

            // Client calls this when it's done processing the successful list of diffs
            let callbackWhenDiffsMerged: CallbackWhenDiffsMerged = { [weak self] success in
                guard let strongSelf = self else { return }
                
                if success {
                    // We successfully merged the changes, so now we are safe to update byte offsets
                    journalByteOffsetsToUpdateAfterMerge.forEach { identifier, byteOffset in
                        strongSelf.journalByteOffsets[identifier] = byteOffset
                    }
                } else {
                    assertionFailure("What do we even do here if merging fails? Is it even possible?")
                }
            }
            
            completion(FetchJournalDiffsResponse.success(type: successType), callbackWhenDiffsMerged)
        }
    }
    
    public func fetchLatestDiffs(completion: @escaping (FetchJournalDiffsResponse, CallbackWhenDiffsMerged?) -> Void) {
        if shouldSync {
            syncFiles(completion: { [weak self] syncFilesResponse in
                guard let strongSelf = self else { return }
                
                switch syncFilesResponse {
                case .success(let updatedFiles):
                    // TODO: See if really care about the updatedFiles when we sync and try to do a fetchLatestDiffsWithoutSync()
                    _ = updatedFiles
                    strongSelf.fetchLatestDiffsWithoutSync(completion: completion)
                    
                case .failure:
                    DispatchQueue.main.async {
                        completion(.failure, nil)
                    }
                }
            })
        } else {
            fetchLatestDiffsWithoutSync(completion: completion)
        }
    }
}
