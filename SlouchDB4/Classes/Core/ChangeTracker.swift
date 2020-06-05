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

public protocol JournalManaging {
    var localIdentifier: String { get }
    
    func addToLocalJournal(command: Command)
    func fetchLatestCommands(completion: @escaping (FetchJournalCommandsResponse, CallbackWhenCommandsMerged?) -> Void)
    
    func save(to folderUrl: URL)
}

public protocol ChangeTrackerDelegate: class {
    func beginCommandExecution(_ changeTracker: ChangeTracker)
    
    func changeTracker(_ changeTracker: ChangeTracker, requestsExecute commands: [Command], for identifier: String, startingAt playbackPosition: PlaybackPosition) -> Bool
    
    func endCommandExecution(_ changeTracker: ChangeTracker)
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
    
    let journalManager: JournalManaging
    let objectHistoryTracker: ObjectHistoryTracker
    
    public weak var delegate: ChangeTrackerDelegate?

    public var localIdentifier: String {
        return journalManager.localIdentifier
    }
    
    public init(journalManager: JournalManaging, objectHistoryStore: ObjectHistoryStoring) {
        self.journalManager = journalManager
        self.objectHistoryTracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
    }
    
    public func save(to folderUrl: URL) {
        objectHistoryTracker.save(to: folderUrl)
        journalManager.save(to: folderUrl)
    }
    
    func enqueue(commands: [Command]) {
        objectHistoryTracker.enqueue(commands: commands)
    }
    
    func processEnqueued() {
        objectHistoryTracker.process(commandExecutor: self)
    }
    
    // Reset the history for a given object
    public func manuallyResetHistory(for identifier: String, commands: [Command]) {
        commands.forEach { command in
            journalManager.addToLocalJournal(command: command)
        }
        let objectHistoryState = ObjectHistoryState(processingState: .fastForward(nextCommandIndex: commands.count),
                                                    commands: commands)
        objectHistoryTracker.objectHistoryStore.update(objectHistoryState: objectHistoryState, for: identifier)
    }
    
    // Local database changes
    public func append(command: Command) {
        journalManager.addToLocalJournal(command: command)
        enqueue(commands: [command])
        processEnqueued()
    }

    public func sync(completion: @escaping (SyncResponse) -> Void, partialResults: @escaping (Double) -> Void) {
        journalManager.fetchLatestCommands(completion: { [weak self] response, callbackWhenCommandsMerged in
            guard let strongSelf = self else { return }
            
            switch response {
            case .success(let type):
                // TODO: Do processing in background thread
                
                let processCommands: ([Command]) -> Void = { commands in
                    strongSelf.enqueue(commands: commands)
                }
                
                switch type {
                case .partialResults(let commands, let percent):
                    processCommands(commands)
                    DispatchQueue.main.async {

                        // Process the partial results and let JournalManager that we've
                        // saved them.
                        strongSelf.processEnqueued()
                        callbackWhenCommandsMerged?(true)

                        // Tell client of ChangeTracker that we have partial results ready.
                        partialResults(percent)

                        // Still have more results, so run sync() again
                        strongSelf.sync(completion: completion, partialResults: partialResults)
                    }
                    
                case .results(let commands):
                    processCommands(commands)
                    DispatchQueue.main.async {
                        strongSelf.processEnqueued()
                        callbackWhenCommandsMerged?(true)
                        
                        completion(.success)
                    }
                }

            case .failure:
                DispatchQueue.main.async {
                    callbackWhenCommandsMerged?(false)
                    completion(.failure)
                }
            }
        })
    }
}

extension ChangeTracker: CommandExecutor {
    public func beginCommandExecution() {
        delegate?.beginCommandExecution(self)
    }
    
    public func execute(commands: [Command], for identifier: String, startingAt playbackPosition: PlaybackPosition) -> Bool {
        return delegate?.changeTracker(self, requestsExecute: commands, for: identifier, startingAt: playbackPosition) ?? false
    }
    
    public func endCommandExecution() {
        delegate?.endCommandExecution(self)
    }
}
