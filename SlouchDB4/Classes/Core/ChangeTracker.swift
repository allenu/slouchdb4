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
    func fetchLatestCommands(completion: @escaping (FetchJournalCommandsResponse, CallbackWhenCommandsMerged?) -> Void)
    
    func save(to folderUrl: URL)
}

public protocol ChangeTrackerDelegate: class {
    func changeTracker(_ changeTracker: ChangeTracker, requestsExecute commands: [Command], for identifier: String, startingAt playbackPosition: PlaybackPosition, completion: @escaping (Bool) -> Void)
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
    
//    func enqueue(commands: [Command]) {
//        queue.async {
//            // TODO: Move to start of process()
//            self.objectHistoryTracker.enqueue(commands: commands)
//        }
//    }
    
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
    
    // Local database changes
    public func append(command: Command, isRemote: Bool = false, completion: CompletionBlock? = nil) {
        queue.async {
            if let completion = completion {
                self.unprocessedCompletions.append(completion)
            }
            if !isRemote {
                self.journalManager.addToLocalJournal(command: command)
            }
            self.unprocessedCommands.append(command)
            self.startProcessingIfNeeded()
        }
    }
    
    public func append(contentsOf commands: [Command], isRemote: Bool = false, completion: CompletionBlock?) {
//        Swift.print("append(contentsOf: \(commands.count) commands")
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
            
//            print("startProcessingIfNeeded running. enqueing \(self.unprocessedCommands.count) unprocessed commands")
            
            // Put things in object tracker and clear unprocessed queue
            self.objectHistoryTracker.enqueue(commands: self.unprocessedCommands)
            self.currentCommandCompletions = self.unprocessedCompletions
            
            self.unprocessedCompletions = []
            self.unprocessedCommands = []
            
            // And then process them
            self.objectHistoryTracker.process(commandExecutor: self, completion: { [weak self] in
                self?.queue.async {
                    
                    // Call completions for all commands that were just processed
                    DispatchQueue.main.async {
                        self?.currentCommandCompletions.forEach { individualCompletion in
                            individualCompletion()
                        }
                        self?.currentCommandCompletions = []
                    }
                    
                    // Leave processing state, but then try processing more, if needed
                    self?.isProcessing = false
                    self?.startProcessingIfNeeded()
                }
            })
        }
    }

    public func sync(completion: @escaping (SyncResponse) -> Void, partialResults: @escaping (Double) -> Void) {
        queue.async {
            guard !self.isSyncing else { return }
            self.isSyncing = true

            self.journalManager.fetchLatestCommands(completion: { [weak self] response, callbackWhenCommandsMerged in
                guard let strongSelf = self else { return }
                
                switch response {
                case .success(let type):
                    switch type {
                    case .partialResults(let commands, let percent):
                        strongSelf.append(contentsOf: commands, isRemote: true, completion: {
                            callbackWhenCommandsMerged?(true)
                            // Tell client of ChangeTracker that we have partial results ready.
                            partialResults(percent)

                            // Still have more results, so run sync() again
                            self?.isSyncing = false
                            strongSelf.sync(completion: completion, partialResults: partialResults)
                        })
                        
                    case .results(let commands):
                        strongSelf.append(contentsOf: commands, isRemote: true, completion: {
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
