//
//  JournalManager.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/25/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

class JournalReaderState {
    var currentCursor: JournalCursor
    var reader: JournalReadable
    
    init(currentCursor: JournalCursor, reader: JournalReadable) {
        self.currentCursor = currentCursor
        self.reader = reader
    }
    
    func refreshSourceFile() throws {
        try reader.refreshSourceFile()
    }
}

class JournalManager: JournalManaging {
    let localJournalWriter: JournalWritable
    var localJournalOffset: UInt64
    
    var localIdentifier: String
    let storageUrl: URL
    let remoteFileStore: RemoteFileStore

    var journals: [String : JournalReaderState]
    
    // Key is the lastPathComponent of the file. However, the lastPathComponent of
    // a journal file is just the guid, so no to worry about file extensions.
    var remoteFileVersion: [String : String] = [:]
    
    // TODO: Make it possible to rotate through local identifiers
    var lastLocalVersionPushed: String

    init(localIdentifier: String, storageUrl: URL, remoteFileStore: RemoteFileStore) {
        // TODO: load all from file
        // TODO: dependency inject
        self.localIdentifier = localIdentifier
        
        self.storageUrl = storageUrl
        localJournalWriter = JournalDataWriter(initialDiffs: [])
        localJournalOffset = 0
        
        // TODO: Load these from the /remotes/ file
        journals = [:]
        
        
        self.remoteFileStore = remoteFileStore
        // TODO: Load from file store
        lastLocalVersionPushed = "unknown"
    }
    
    func addToLocalJournal(diff: ObjectDiff) {
        localJournalOffset = localJournalWriter.append(diffs: [diff])
    }
    
    func syncFiles(completion: @escaping (SyncFilesResponse) -> Void) {
        var pushSucceeded = false
        
        let doFetchRemoteFiles: ([String : String]) -> Void = { [weak self] fetchedVersions in
            guard let strongSelf = self else { return }
            
            // Fetch all those files that differ from local version
            let filesToFetch: [String] = fetchedVersions.filter( { keyValue in
                let fetchedVersion = keyValue.value
                let localKnownVersion = strongSelf.remoteFileVersion[keyValue.key] ?? "not-found"
                
                let shouldFetchFile: Bool
                if keyValue.key == strongSelf.localIdentifier {
                    // Never pull a local file!
                    shouldFetchFile = false
                } else {
                    shouldFetchFile = localKnownVersion != fetchedVersion
                }

                return shouldFetchFile
            }).map { $0.key }
            
            if filesToFetch.count > 0 {
                strongSelf.remoteFileStore.fetchFiles(identifiers: filesToFetch) { [weak self] response in
                    guard let strongSelf = self else { return }
                    
                    switch response {
                    case .success(let fileAndVersion):
                        
                        let updatedFiles: [String] = fileAndVersion.map { $0.url.lastPathComponent }
                        fileAndVersion.forEach { fileAndVersion in
                            let remoteFileUrl = fileAndVersion.url
                            let fileIdentifier = remoteFileUrl.lastPathComponent
                            strongSelf.remoteFileVersion[fileIdentifier] = fileAndVersion.version
                            
                            // TODO: Copy local file now
                            let localFileUrl: URL = strongSelf.storageUrl.appendingPathComponent("remotes/\(fileIdentifier)")
                            
                            // Add journal readers for each journal that we're missing
                            if let existingJournalReaderState = strongSelf.journals[fileIdentifier] {
                                // Let it know local file changed
                                do {
                                    try existingJournalReaderState.refreshSourceFile()
                                } catch {
                                    assertionFailure()
                                    // Not sure how to handle this ...
                                }
                            } else {
                                // Add new entry since it wasn't there yet
                                // TODO: use Factory instead of refering to JournalFileReader class directly
                                do {
                                    strongSelf.journals[fileIdentifier] =
                                        JournalReaderState(currentCursor: JournalCursor(nextDiffIndex: 0, byteOffset: 0, endOfFile: false),
                                                           reader: try JournalFileReader(url: localFileUrl))
                                } catch {
                                    assertionFailure()
                                    print("Couldn't load file \(localFileUrl)")
                                }
                            }
                        }
                        
                        DispatchQueue.main.async {
                            completion(.success(updatedFiles: updatedFiles))
                        }
                        
                    case .failure(let reason):
                        DispatchQueue.main.async {
                            completion(.failure)
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
                    // TODO: path is not final
                    let localFileUrl = strongSelf.storageUrl.appendingPathComponent("local/\(strongSelf.localIdentifier)")
                    
                    strongSelf.remoteFileStore.push(localFile: localFileUrl) { [weak self] pushResponse in
                        guard let strongSelf = self else { return }
                        
                        switch pushResponse {
                        case .success(let version):
                            // Push succeeded.
                            pushSucceeded = true
                            strongSelf.lastLocalVersionPushed = version
                            
                        case .failure(let reason):
                            pushSucceeded = false
                        }
                    }
                } else {
                    pushSucceeded = true
                }
                
                // TODO: Do something with push success ... ? Like fail?
                _ = pushSucceeded
                
                doFetchRemoteFiles(fetchedVersions)
                
            case .failure(let reason):
                DispatchQueue.main.async {
                    completion(.failure)
                }
            }
        })
    }
    
    func fetchLatestDiffsWithoutSync(completion: @escaping (FetchJournalDiffsResponse, CallbackWhenDiffsMerged?) -> Void) {
        let maxDiffs: Int = 100
        
        // Go through journals getting up to maxDiffs until there are no more changes
        // or we reach maxDiffs.
        
        var diffs: [ObjectDiff] = []
        var journalsHaveNoMoreChanges = false
        var journalCursorsToUpdateAfterMerge: [String : JournalCursor] = [:]
        
        while !journalsHaveNoMoreChanges {
            // Find a journal that has changes and consume as much as possible
            
            var loadedJournalChanges = false
            journals.forEach { identifier, journalReaderState in
                if diffs.count >= maxDiffs {
                    // Do nothing. We have enough diffs.
                } else {
                    // Try to get changes from this journal, a max of N
                    let maxDiffsAttemptToFetch = maxDiffs - diffs.count
                    
                    let currentCursor = journalReaderState.currentCursor
                    let readResult = journalReaderState.reader.readNext(cursor: currentCursor, maxCount: maxDiffsAttemptToFetch)
                    
                    if readResult.diffs.count > 0 {
                        diffs.append(contentsOf: readResult.diffs)
                        loadedJournalChanges = true
                        
                        journalCursorsToUpdateAfterMerge[identifier] = readResult.cursor
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
                    // We successfully merged the changes, so now we are safe to update our journal cursors
                    journalCursorsToUpdateAfterMerge.forEach { identifier, cursor in
                        if let journalReaderState = strongSelf.journals[identifier] {
                            journalReaderState.currentCursor = cursor
                        } else {
                            assertionFailure()
                        }
                    }
                } else {
                    assertionFailure("What do we even do here if merging fails? Is it even possible?")
                }
            }
            
            completion(FetchJournalDiffsResponse.success(type: successType), callbackWhenDiffsMerged)
        }
    }
    
    func fetchLatestDiffs(completion: @escaping (FetchJournalDiffsResponse, CallbackWhenDiffsMerged?) -> Void) {
        // TODO: Make file sync optional
        
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
    }
}
