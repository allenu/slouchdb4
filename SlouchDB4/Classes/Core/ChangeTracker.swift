//
//  ChangeTracker.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public enum SyncFilesFailureReason {
    case pushFailed
    case fetchRemoteVersionsFailed
    case fetchRemoteFilesFailed
}

public enum SyncFilesResponse {
    case success(updatedFiles: [String])
    case failure(reason: SyncFilesFailureReason)
}

public enum FetchJournalSuccessType {
    case partialResults(commands: [Command], percent: Double)
    case results(commands: [Command])
}

public enum FetchJournalCommandsResponse {
    case success(type: FetchJournalSuccessType)
    // case successNoChanges
    case failure
}

// CallbackWhenCommandsMerged is passed in to ensure that when the caller gets the commands it tells us
// it is done so that we can save the updated journal states to file. This is to ensure that if
// anything happens during the merge. On failure, the callback is nil since we do not care.
public typealias CallbackWhenCommandsMerged = (Bool) -> Void

public typealias CompletionBlock = () -> Void

public protocol JournalManaging {
    var localIdentifier: String { get }
    
    func addToLocalJournal(command: Command)
    func fetchLatestCommands(skipRemoteFetch: Bool, completion: @escaping (FetchJournalCommandsResponse, CallbackWhenCommandsMerged?) -> Void)
    
    func save(to folderUrl: URL)
    
    func resetSyncState()
}

public protocol ChangeTrackerDelegate: class {
    func changeTracker(_ changeTracker: ChangeTracker, requestsExecute commands: [Command], for identifier: String, startingAt playbackPosition: PlaybackPosition, completion: @escaping (Bool) -> Void)
    
    // For logging
    func didStartFetchLatestCommands(for changeTracker: ChangeTracker)
    func changeTracker(_ changeTracker: ChangeTracker, didFetchLatestCommandsWithResponse: FetchJournalCommandsResponse)

    func changeTracker(_ changeTracker: ChangeTracker, didStartAppendCommands commands: [Command])
    func didFinishAppendCommands(_ changeTracker: ChangeTracker)

    func didStartProcessCommands(for changeTracker: ChangeTracker)
    func didEndProcessCommands(for changeTracker: ChangeTracker)
}

// ChangeTracker does the following:
// - stores commands on local Insert, Update, Delete requests into local journal
// - coordinates "merging" remote changes into local object history
// -
//
public class ChangeTracker {
    public enum SyncResponse {
        case success
        case failure
    }
    
    public let queue = DispatchQueue(label: "ChangeTracker.Data-\(UUID().uuidString)", attributes: [])
    
    let journalManager: JournalManaging
    let objectHistoryTracker: ObjectHistoryTracker
    
    var bulkDispatchGroups: [String : DispatchGroup] = [:]
    
    var unprocessedCommands: [Command] = []
    var unprocessedCompletions: [CompletionBlock] = []
    
    var currentCommandCompletions: [CompletionBlock] = []
    
    var isSyncing: Bool = false
    var isProcessing = false
    
    public var debugIdentifier = "unknown"

    public weak var delegate: ChangeTrackerDelegate?

    public var localIdentifier: String {
        return journalManager.localIdentifier
    }
    
    public init(journalManager: JournalManaging, objectHistoryStore: ObjectHistoryStoring) {
        self.journalManager = journalManager
        self.objectHistoryTracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
    }
    
    public func save(to folderUrl: URL, synchronous: Bool = false) {
        let saveBlock = {
            self.objectHistoryTracker.save(to: folderUrl)
            self.journalManager.save(to: folderUrl)
        }
        
        if synchronous {
            queue.sync {
                saveBlock()
            }
        } else {
            queue.async {
                saveBlock()
            }
        }
    }
    
    // Reset the history for a given object
    public func manuallyResetHistory(for identifier: String, commands: [Command]) {
        queue.async {
            commands.forEach { command in
                self.journalManager.addToLocalJournal(command: command)
            }
            let objectHistoryState = ObjectHistoryState(processingState: .fastForward(nextCommandIndex: commands.count),
                                                        commands: commands)
            self.objectHistoryTracker.objectHistoryStore.update(objectHistoryState: objectHistoryState, for: identifier)
        }
    }
    
    // Add commands to the tracker.
    //
    // completion() will be called once the commands are executed. Note that even if the commands
    // were already in the system (in the case of a sync, which leads to the same commands being
    // attempted to be appended), completion() will still be called when the commands are processed.
    // This is to ensure symmetry and let the client always put code in the completion if it needs
    // it to depend on the execution order.
    public func append(command: Command, isRemote: Bool = false, completion: CompletionBlock? = nil) {
        queue.async {
//            if let completion = completion {
            // Must have a completion in the list to make unprocessedCompletions and unprocessedCommands the same size
            let emptyCompletion: CompletionBlock = {}
            self.unprocessedCompletions.append(completion ?? emptyCompletion)
            if !isRemote {
                self.journalManager.addToLocalJournal(command: command)
            }
            self.unprocessedCommands.append(command)
            self.startProcessingIfNeeded()
            
            assert(self.unprocessedCommands.count == self.unprocessedCompletions.count)
        }
    }
    
    public func append(contentsOf commands: [Command], isRemote: Bool = false, completion: CompletionBlock?) {
        queue.async {
            guard commands.count > 0 else {
                self.queue.async {
                    completion?()
                }
                return
            }
            
            if let completion = completion {
                // We have a single completion for multiple commands. Let's set up a dispatch group
                // that notifies when all commands are executed.
                let dispatchGroup = DispatchGroup()
                commands.forEach { command in
                    dispatchGroup.enter()
                    
                    let commandCompletion = {
                        dispatchGroup.leave()
                    }
                    self.unprocessedCompletions.append(commandCompletion)
                }
                
                let bulkIdentifier = UUID().uuidString
                dispatchGroup.notify(queue: self.queue, execute: {
                    completion()
                    self.bulkDispatchGroups.removeValue(forKey: bulkIdentifier)
                })
                
                self.bulkDispatchGroups[bulkIdentifier] = dispatchGroup
            }

            if !isRemote {
                commands.forEach { self.journalManager.addToLocalJournal(command: $0) }
            }
            self.unprocessedCommands.append(contentsOf: commands)
            
            self.startProcessingIfNeeded()
        }
    }
    
    func startProcessingIfNeeded() {
        queue.async {
            guard !self.isProcessing else { return }
            guard self.unprocessedCommands.count > 0 else { return }
            
            self.isProcessing = true
            
            
            // TODO: Is this right? Force only processing up to 100 commands at a time to avoid starving other ChangeTracker
            // tasks.
            let maxProcessedCommands = 100
            
            let commandsToProcess = Array(self.unprocessedCommands.prefix(maxProcessedCommands))
            let completionsToProcess = Array(self.unprocessedCompletions.prefix(maxProcessedCommands))

            // Put things in object tracker and clear unprocessed queue
            self.objectHistoryTracker.enqueue(commands: commandsToProcess)
            self.currentCommandCompletions = completionsToProcess
            
            self.unprocessedCommands.removeFirst(commandsToProcess.count)
            self.unprocessedCompletions.removeFirst(completionsToProcess.count)

            // These must always be the same size
            assert(self.unprocessedCommands.count == self.unprocessedCompletions.count)
            
            // And then process them
            self.delegate?.didStartProcessCommands(for: self)
            
            self.objectHistoryTracker.process(commandExecutor: self, completion: { [weak self] in
                self?.queue.async {
                    
                    guard let strongSelf = self else { return }
                    strongSelf.delegate?.didEndProcessCommands(for: strongSelf)
                    
                    // Call completions for all commands that were just processed
                    DispatchQueue.main.async {
//                        let count = self?.currentCommandCompletions.count ?? 0
//                        print("calling \(count) currentCommandCompletions")
                        self?.currentCommandCompletions.forEach { individualCompletion in
                            individualCompletion()
                        }
                        self?.currentCommandCompletions = []
                        
                        // Leave processing state, but then try processing more, if needed
                        // NOTE: This must be dispatched after the currentCommandCompletions above are processed.
                        self?.queue.async {
                            self?.isProcessing = false
                            DispatchQueue.main.async {
                                self?.startProcessingIfNeeded()
                            }
                        }
                    }
                }
            })
        }
    }

    public func sync(skipRemoteFetch: Bool = false, completion: @escaping (SyncResponse) -> Void, partialResults: @escaping (Double) -> Void) {
        queue.async {
            guard !self.isSyncing else {
                assertionFailure("Called while already syncing. Don't let this happen.")
                return }
            
            self.isSyncing = true

            // print("sync \(self.debugIdentifier) - calling journalManager.fetchLatestCommands")
            
            self.delegate?.didStartFetchLatestCommands(for: self)
            
            self.journalManager.fetchLatestCommands(skipRemoteFetch: skipRemoteFetch,
                                                    completion: { [weak self] response, callbackWhenCommandsMerged in
                guard let strongSelf = self else { return }
                                                        
                strongSelf.delegate?.changeTracker(strongSelf, didFetchLatestCommandsWithResponse: response)
                                                        
//                print("changeTracker \(strongSelf.debugIdentifier) fetchLatestCommands => \(response)")
                
                switch response {
                case .success(let type):
                    switch type {
                    case .partialResults(let commands, let percent):
                        strongSelf.delegate?.changeTracker(strongSelf, didStartAppendCommands: commands)
                        
                        strongSelf.append(contentsOf: commands, isRemote: true, completion: {
                            
                            strongSelf.delegate?.didFinishAppendCommands(strongSelf)
                            
                            callbackWhenCommandsMerged?(true)
                            // Tell client of ChangeTracker that we have partial results ready.
                            partialResults(percent)

                            // Still have more results, so run sync() again
                            self?.isSyncing = false
                            
                            // NOTE: We explicitly skip remote fetch now to allow us to process all downloaded
                            // results first.
                            strongSelf.sync(skipRemoteFetch: true, completion: completion, partialResults: partialResults)
                        })
                        
                    case .results(let commands):
                        strongSelf.delegate?.changeTracker(strongSelf, didStartAppendCommands: commands)

                        strongSelf.append(contentsOf: commands, isRemote: true, completion: {
                            strongSelf.delegate?.didFinishAppendCommands(strongSelf)

                            callbackWhenCommandsMerged?(true)
                            
                            self?.isSyncing = false
                            completion(.success)
                        })
                    }

                case .failure:
                    callbackWhenCommandsMerged?(false)
                    self?.isSyncing = false
                    completion(.failure)
                } // switch response
            }) // fetchLatestCommands(completion:)
        }
    }
    
    public func resetSyncState() {
        journalManager.resetSyncState()
        objectHistoryTracker.resetSyncState()
    }
}

extension ChangeTracker: CommandExecutor {
    public func execute(commands: [Command], for identifier: String, startingAt playbackPosition: PlaybackPosition, completion: @escaping (Bool) -> Void) {
        assert(delegate != nil)
        
        delegate?.changeTracker(self, requestsExecute: commands,
                                for: identifier,
                                startingAt: playbackPosition,
                                completion: completion)
    }
}
