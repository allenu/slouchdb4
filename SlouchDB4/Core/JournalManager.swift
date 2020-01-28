//
//  JournalManager.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/25/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

protocol JournalFileManaging {
    func writeLocal(diffs: [ObjectDiff], to identifier: String)
    
    // Get the url for a local journal file (searches only in /local/)
    func localFileUrl(for identifier: String) -> URL?

    // We have a newer version of a remote journal file, so replace the file contents with the new one and
    // call completion when done copying.
    func replaceRemoteJournalFile(identifier: String, with url: URL, completion: @escaping () -> Void)
    
    func readNextDiffs(from identifier: String, byteOffset: UInt64, maxDiffs: Int) -> JournalReadResult
}

struct JournalManagerStoredState: Codable {
    let localIdentifier: String
    let journalByteOffsets: [String : UInt64]
    let remoteFileVersion: [String : String]
    let lastLocalVersionPushed: String
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

class JournalManager: JournalManaging {
    let remoteFileStore: RemoteFileStore
    var journalFileManager: JournalFileManaging

    // --------------------------------------
    // State data -- should come from storage
    // --------------------------------------
    var localIdentifier: String
    var journalByteOffsets: [String : UInt64]
    
    // Key is the lastPathComponent of the file. However, the lastPathComponent of
    // a journal file is just the guid, so no to worry about file extensions.
    var remoteFileVersion: [String : String] = [:]
    
    // TODO: Make it possible to rotate through local identifiers
    var lastLocalVersionPushed: String

    init(journalFileManager: JournalFileManaging, remoteFileStore: RemoteFileStore, storedState: JournalManagerStoredState) {
        self.journalFileManager = journalFileManager
        self.remoteFileStore = remoteFileStore

        self.localIdentifier = storedState.localIdentifier
        self.journalByteOffsets = storedState.journalByteOffsets
        self.lastLocalVersionPushed = storedState.lastLocalVersionPushed
    }
    
    func save() {
        // Save data to StoredState
    }
    
    func addToLocalJournal(diff: ObjectDiff) {
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
                        let updatedFiles: [String] = fileAndVersion.map { $0.url.lastPathComponent }
                        
                        let dispatchGroup = DispatchGroup()
                        
                        fileAndVersion.forEach { fileAndVersion in
                            let remoteFileUrl = fileAndVersion.url
                            let fileIdentifier = remoteFileUrl.lastPathComponent
                            strongSelf.remoteFileVersion[fileIdentifier] = fileAndVersion.version
                            
                            dispatchGroup.enter()
                            
                            // Replace the remote journal file and when done update the state of this journal entry
                            strongSelf
                                .journalFileManager
                                .replaceRemoteJournalFile(identifier: fileIdentifier, with: remoteFileUrl, completion: {

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
                        
                    case .failure(let reason):
                        DispatchQueue.main.async {
                            completion(.failure(reason: .fetchRemoteFilesFailed))
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
        
        remoteFileStore.fetchRemoteFileVersions(completionHandler: { [weak self] fetchedRemoteFileVersionsResponse in
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
                                completion(.failure(reason: .pushFailed))
                            }
                        }
                    } else {
                        // Let's pretend the push succeeded since we can't recover from a scenario where a local
                        // file we expected doesn't exist. Just gracefully move on.
                        assertionFailure("Local file doesn't exist to push!")

                        doFetchRemoteFiles(fetchedVersions)
                    }
                } else {
                    // No files to push, so treat as success and go onto next step
                    doFetchRemoteFiles(fetchedVersions)
                }
                
            case .failure(let reason):
                DispatchQueue.main.async {
                    completion(.failure(reason: .fetchRemoteVersionsFailed))
                }
            }
        })
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
        let maxDiffs: Int = 100
        
        // Go through journals getting up to maxDiffs until there are no more changes
        // or we reach maxDiffs.
        
        var diffs: [ObjectDiff] = []
        var journalsHaveNoMoreChanges = false
        var journalByteOffsetsToUpdateAfterMerge: [String : UInt64] = [:]
        
        while !journalsHaveNoMoreChanges {
            // Find a journal that has changes and consume as much as possible
            
            var loadedJournalChanges = false
            journalByteOffsets.forEach { identifier, byteOffset in
                if diffs.count >= maxDiffs {
                    // Do nothing. We have enough diffs.
                } else {
                    // Try to get changes from this journal, a max of N
                    let maxDiffsAttemptToFetch = maxDiffs - diffs.count
                    
                    let readResult = self.journalFileManager.readNextDiffs(from: identifier,
                                                                           byteOffset: byteOffset,
                                                                           maxDiffs: maxDiffsAttemptToFetch)
                    
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
            if diffs.count == maxDiffs {
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
    
    func fetchLatestDiffs(completion: @escaping (FetchJournalDiffsResponse, CallbackWhenDiffsMerged?) -> Void) {
        // TODO: Add logic to see if we should sync files first
        
        let syncFilesFirst = true
        
        if syncFilesFirst {
            syncFiles(completion: { [weak self] syncFilesResponse in
                guard let strongSelf = self else { return }
                
                switch syncFilesResponse {
                case .success(let updatedFiles):
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
