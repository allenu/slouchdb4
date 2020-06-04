//
//  ObjectHistoryStore.swift
//  Pods
//
//  Created by Allen Ussher on 2/20/20.
//

import Foundation
import SlouchDB4


enum ObjectHistoryProcessingStateFileRepresentation: String, Codable {
    case fastForward
    case replay
}

struct ObjectHistoryStateFileRepresentation: Codable {
    let processingState: ObjectHistoryProcessingStateFileRepresentation
    let fastForwardNextCommandIndex: Int // only used if fastForward
    
    let commands: [Command]
}

struct ObjectHistoryFileRepresentation: Codable {
    let histories: [String : ObjectHistoryStateFileRepresentation]
    let pendingUpdates: [String]
}


public class InMemObjectHistoryStore: ObjectHistoryStoring {
    // init with data here
    var histories: [String : ObjectHistoryState]
    
    // Cache which objects need update so that process() is faster.
    var _pendingUpdates: Set<String>
    
    public init(histories: [String : ObjectHistoryState] = [:], pendingUpdates: [String] = []) {
        self.histories = histories
        self._pendingUpdates = Set<String>(pendingUpdates)
    }

    public static func create(from folderUrl: URL) -> ObjectHistoryStoring? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var objectHistoryStore: ObjectHistoryStoring?
        do {
            let fileUrl = folderUrl.appendingPathComponent("object-history.json")
            let data = try Data(contentsOf: fileUrl)
            let fileRepresentation: ObjectHistoryFileRepresentation = try decoder.decode(ObjectHistoryFileRepresentation.self, from: data)
            var histories: [String : ObjectHistoryState] = [:]
            
            fileRepresentation.histories.forEach { keyValue in
                let identifier = keyValue.key
                let objectHistoryStateRepresentation = keyValue.value
            
                let processingState: ObjectHistoryProcessingState
                switch objectHistoryStateRepresentation.processingState {
                case .fastForward:
                    processingState = .fastForward(nextCommandIndex: objectHistoryStateRepresentation.fastForwardNextCommandIndex)
                    
                case .replay:
                    processingState = .replay
                }
                
                let history = ObjectHistoryState(processingState: processingState,
                                                 commands: objectHistoryStateRepresentation.commands)
                histories[identifier] = history
            }
            objectHistoryStore = InMemObjectHistoryStore(histories: histories, pendingUpdates: fileRepresentation.pendingUpdates)
        } catch {
            print("Error loading Tracker")
        }
        return objectHistoryStore
    }
    
    public func save(to folderUrl: URL) {
        let fileUrl = folderUrl.appendingPathComponent("object-history.json")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        let pendingUpdates = Array(self._pendingUpdates)
        var historiesFileRepresentation: [String : ObjectHistoryStateFileRepresentation] = [:]
        self.histories.forEach { keyValue in
            let identifier = keyValue.key
            let history = keyValue.value
            
            let fastForwardNextCommandIndex: Int
            let processingStateFileRepresentation: ObjectHistoryProcessingStateFileRepresentation
            switch history.processingState {
            case .fastForward(let nextCommandIndex):
                processingStateFileRepresentation = .fastForward
                fastForwardNextCommandIndex = nextCommandIndex
                
            case .replay:
                processingStateFileRepresentation = .replay
                fastForwardNextCommandIndex = 0
            }
            
            let commands = history.commands
            let historyFileRepresentation = ObjectHistoryStateFileRepresentation(processingState: processingStateFileRepresentation,
                                                                                 fastForwardNextCommandIndex: fastForwardNextCommandIndex,
                                                                                 commands: commands)
            historiesFileRepresentation[identifier] = historyFileRepresentation
        }
        let fileData = ObjectHistoryFileRepresentation(histories: historiesFileRepresentation, pendingUpdates: pendingUpdates)
        do {
            let data = try encoder.encode(fileData)
            try data.write(to: fileUrl)
        } catch {
            print("Error saving")
        }
    }

    public func insertPendingUpdate(for identifier: String) {
        _pendingUpdates.insert(identifier)
    }
    
    public func removePendingUpdate(for identifier: String) {
        _pendingUpdates.remove(identifier)
    }
    
    public func pendingUpdates() -> [String] {
        return Array(_pendingUpdates)
    }
    
    public func objectHistoryState(for identifier: String) -> ObjectHistoryState? {
        return histories[identifier]
    }
    
    public func update(objectHistoryState: ObjectHistoryState, for identifier: String) {
        histories[identifier] = objectHistoryState
    }
}
