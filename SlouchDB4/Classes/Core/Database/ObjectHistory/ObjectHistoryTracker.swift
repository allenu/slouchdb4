//
//  ObjectHistoryTracker.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/24/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public enum ObjectHistoryProcessingState {
    case fastForward(nextCommandIndex: Int)
    case replay
}

public enum PlaybackPosition {
    case start
    case currentPosition
}

public protocol CommandExecutor: AnyObject {
    func execute(commands: [Command], for identifier: String,
                 startingAt playbackPosition: PlaybackPosition,
                 completion: @escaping (Bool) -> Void)
}

public struct Command: Codable {
    // Object to modify
    public let objectIdentifier: String
    public let commandIdentifier: String
    public let timestamp: Date
    
    // Opaque data that the client encodes/decodes as it cares to
    public let operation: Data
    
    public init(objectIdentifier: String,
                commandIdentifier: String = UUID().uuidString,
                timestamp: Date = Date(),
                operation: Data) {
        self.objectIdentifier = objectIdentifier
        self.commandIdentifier = commandIdentifier
        self.timestamp = timestamp
        self.operation = operation
    }
}

public class ObjectHistoryState {
    public var processingState: ObjectHistoryProcessingState
    public var commands: [Command]
    
    public init(processingState: ObjectHistoryProcessingState,
         commands: [Command] = []) {
        self.processingState = processingState
        self.commands = commands
    }
}

public class ObjectHistoryTracker {
    let objectHistoryStore: ObjectHistoryStoring
    
    public init(objectHistoryStore: ObjectHistoryStoring) {
        self.objectHistoryStore = objectHistoryStore
    }
    
    func save(to folderUrl: URL) {
        objectHistoryStore.save(to: folderUrl)
    }
    
    // This queues up the commands provided and updates the histories of each object.
    public func enqueue(commands: [Command]) {
        commands.forEach { command in
            if let objectHistoryState = objectHistoryStore.objectHistoryState(for: command.objectIdentifier) {
                let originalCommandCount = objectHistoryState.commands.count

                if let lastCommand = objectHistoryState.commands.last {
                    if command.timestamp > lastCommand.timestamp {
                        // See if this command's timestamp is newer than the last one, we can
                        // just append.
                        // processingState is whatever it was
                        objectHistoryState.commands.append(command)
                    } else if command.timestamp == lastCommand.timestamp {
                        // Timestamps are equal, so see if it's the same command we are inserting
                        // again...
                        if command.commandIdentifier == lastCommand.commandIdentifier {
                            // Same command. We already know about it, so do nothing.
                        } else {
                            // New command! Append it. processingState is whatever it was
                            objectHistoryState.commands.append(command)
                        }
                    } else {
                        // This command may change history. Find where to insert it.
                        let firstCommandNewerIndex = objectHistoryState.commands.firstIndex(where: { $0.timestamp >= command.timestamp })!
                        
                        // See if this is the same command as the one we're inserting
                        let firstCommandNewer = objectHistoryState.commands[firstCommandNewerIndex]
                        if firstCommandNewer.commandIdentifier == command.commandIdentifier {
                            // Already know about it, so don't insert.
                        } else {
                            // Insert command before that one
                            objectHistoryState.commands.insert(command, at: firstCommandNewerIndex)
                            
                            // Rewriting history
                            objectHistoryState.processingState = .replay
                        }
                    }
                } else {
                    // Strange, there are no commands yet. Handle it gracefully.
                    objectHistoryState.commands.append(command)
                    objectHistoryState.processingState = .replay
                }
                
                // See if we ended up updating the commands. If so, record that it changed.
                if objectHistoryState.commands.count != originalCommandCount {
                    // Update it in the datastore
                    objectHistoryStore.update(objectHistoryState: objectHistoryState, for: command.objectIdentifier)
                }
                
                // Even if nothing changed, treat it as a processed command.
                objectHistoryStore.insertPendingUpdate(for: command.objectIdentifier)
                
            } else {
                // Doesn't exist yet, so create it
                let objectHistoryState = ObjectHistoryState(processingState: .replay, commands: [command])
                objectHistoryStore.update(objectHistoryState: objectHistoryState, for: command.objectIdentifier)
                
                objectHistoryStore.insertPendingUpdate(for: command.objectIdentifier)
            }
        }
    }
    
    // TODO: Make it so that process() can do a maximum of N updates at a time (to reduce
    // memory consumption). We can keep calling it until MergeResult is empty.
    
    // Go through pending commands and process the changes they would generate.
    // This mutates our internal state to consider those changes applied.
    
    func process(commandExecutor: CommandExecutor, completion: @escaping CompletionBlock) {
        let pendingUpdates = objectHistoryStore.pendingUpdates()
        
        DispatchQueue.global(qos: .userInitiated).async {
            let dispatchGroup = DispatchGroup()
            
            pendingUpdates.forEach { identifier in
                if let objectHistoryState = self.objectHistoryStore.objectHistoryState(for: identifier) {
                    switch objectHistoryState.processingState {
                    case .fastForward(let nextCommandIndex):
                        
                        let hasNewCommands = objectHistoryState.commands.count > nextCommandIndex
                        if hasNewCommands {
                            let justNewCommands = Array(objectHistoryState.commands.dropFirst(nextCommandIndex))
                            if justNewCommands.count > 0 {
                                dispatchGroup.enter()
                                commandExecutor.execute(commands: justNewCommands, for: identifier, startingAt: .currentPosition, completion: { success in
                                    
                                    if success {
                                        objectHistoryState.processingState = .fastForward(nextCommandIndex: objectHistoryState.commands.count)
                                        self.objectHistoryStore.update(objectHistoryState: objectHistoryState, for: identifier)

                                        self.objectHistoryStore.removePendingUpdate(for: identifier)
                                    } else {
                                        // Incomplete set of commands, so keep in the store and hope that we sync newer info
                                        // that will make it complete later
                                    }
                                    dispatchGroup.leave()
                                })
                            }
                        } else {
                            // 2021-10-11 BUGFIX: Even if there are no new commands, remove the pending update so we don't waste time
                            // trying to process it again.
                            self.objectHistoryStore.removePendingUpdate(for: identifier)
                        }
                        
                    case .replay:
                        if objectHistoryState.commands.count > 0 {
                            dispatchGroup.enter()
                            
                            commandExecutor.execute(commands: objectHistoryState.commands, for: identifier, startingAt: .start, completion: { success in
                                
                                if success {
                                    objectHistoryState.processingState = .fastForward(nextCommandIndex: objectHistoryState.commands.count)
                                    self.objectHistoryStore.update(objectHistoryState: objectHistoryState, for: identifier)
                                    self.objectHistoryStore.removePendingUpdate(for: identifier)
                                } else {
                                    // Incomplete set of commands, so keep in the store and hope that we sync newer info
                                    // that will make it complete later
                                }
                                dispatchGroup.leave()
                            })
                        } else {
                            // No commands to play back, so remove the pending updates marker
                            self.objectHistoryStore.removePendingUpdate(for: identifier)
                        }
                    }
                } else {
                    Swift.print("Could not find object history state for object \(identifier)")
                }
            }

            dispatchGroup.wait()
            completion()
        }
    }
    
    func resetSyncState() {
        objectHistoryStore.resetSyncState()
    }
}
