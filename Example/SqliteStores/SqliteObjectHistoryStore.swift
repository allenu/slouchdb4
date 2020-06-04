//
//  SqliteObjectHistoryStore.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 3/4/20.
//  Copyright © 2020 CocoaPods. All rights reserved.
//

import Foundation
import SQLite
import SlouchDB4

class SqliteObjectHistoryStore: ObjectHistoryStoring {
    
    static func objectHistoryStoreExists(folderUrl: URL) -> Bool {
        let objectHistorySqliteUrl = folderUrl.appendingPathComponent(sqliteFilename)
        return FileManager.default.fileExists(atPath: objectHistorySqliteUrl.path)
    }
    
    static func copyObjectHistoryStore(from sourceUrl: URL, to destinationUrl: URL) {
        let sourceFileUrl = sourceUrl.appendingPathComponent(SqliteObjectHistoryStore.sqliteFilename)
        let destinationFileUrl = destinationUrl.appendingPathComponent(SqliteObjectHistoryStore.sqliteFilename)
        
        // Remove file at destination if it's already there
        if FileManager.default.fileExists(atPath: destinationFileUrl.path) {
            try! FileManager.default.removeItem(at: destinationFileUrl)
        }
        
        try! FileManager.default.copyItem(at: sourceFileUrl, to: destinationFileUrl)
    }
    
    static let sqliteFilename = "object-history.sqlite3"
    
    let connection: Connection

    let pendingUpdatesTable: Table
    let processingStatesTable: Table
    let commandsTable: Table
    
//    let autoIdColumn = Expression<Int64>("autoId")
    let idColumn = Expression<String>("identifier")
    let objectIdColumn = Expression<String>("objectIdentifier")
    let commandIdColumn = Expression<String>("commandIdentifier")
    let processingStateTypeColumn = Expression<Int64>("type")
    let commandIndexColumn = Expression<Int64>("commandIndex")
    let timestampColumn = Expression<Date>("timestamp")
    let operationColumn = Expression<Data>("operation")
    
    let databaseWriteUrl: URL

    // NOTE: url is meant to be a file path that we can constantly write to. It should not be
    // the Document bundle folder itself. Use a temporary folder and when it comes time to save
    // to the doc folder, use save(to:)
    init?(folderUrl: URL) {
        databaseWriteUrl = folderUrl.appendingPathComponent(SqliteObjectHistoryStore.sqliteFilename)
        var connection: Connection?
        do {
            connection = try Connection(databaseWriteUrl.path)
        } catch {
            connection = nil
        }

        if let connection = connection {
            self.connection = connection
            
            // Initialize three tables:
            // - PendingUpdates -- database of just identifier strings
            // - ProcessingStates -- database of processing state type + index (if ffwd)
            // - Commands -- database of commands with primary key of objectIdentifier + timestamp
            pendingUpdatesTable = Table("PendingUpdates")
            processingStatesTable = Table("ProcessingStates")
            commandsTable = Table("Commands")
            
            do {
                try setupTables()
            } catch {
                print("Error setting up tables: \(error)")
                // TODO: Only return nil on certain errors. If tables already exist, we will
                // get error back.
            }
        } else {
            return nil
        }
    }
    
    func setupTables() throws {
        try connection.run(pendingUpdatesTable.create { t in
            t.column(idColumn, primaryKey: true)
        })
        
        try connection.run(processingStatesTable.create { t in
            t.column(idColumn, primaryKey: true)
            t.column(processingStateTypeColumn)
            t.column(commandIndexColumn)
        })
        
        try connection.run(commandsTable.create { t in
//            t.column(autoIdColumn, primaryKey: true)
            t.column(objectIdColumn)
            t.column(commandIdColumn)
            t.column(timestampColumn)
            t.column(operationColumn)
        })
    }
    
    func insertPendingUpdate(for identifier: String) {
        let insert = pendingUpdatesTable.insert(
            idColumn <- identifier
            )
        
        do {
            let rowid = try connection.run(insert)
            print("inserted row \(rowid)")
        } catch {
            print("Failed to insert update with identifier \(identifier) -- may already exist? error: \(error)")
        }
    }
    
    func removePendingUpdate(for identifier: String) {
        let deleteQuery = pendingUpdatesTable.filter(idColumn == identifier)
        
        do {
            if try connection.run(deleteQuery.delete()) > 0 {
                print("deleted items matching \(identifier)")
            } else {
                print("no items found")
            }
        } catch {
            print("delete failed: \(error)")
        }
    }
    
    func pendingUpdates() -> [String] {
        do {
            let allPendingUpdateRows = Array(try connection.prepare(pendingUpdatesTable))
            let allPendingUpdates = allPendingUpdateRows.map { $0[idColumn] }
            return allPendingUpdates
        } catch {
            print("Couldn't get all updates")
            return []
        }
    }
    
    func objectHistoryState(for identifier: String) -> ObjectHistoryState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Fetch the processing state, if it exists
        let processingStateQuery = processingStatesTable.filter(idColumn == identifier)
        
        do {
            let result = try connection.prepare(processingStateQuery)
            if let processingStateRow = result.makeIterator().next() {
                
                let processingStateType: Int64 = processingStateRow[processingStateTypeColumn]
                let commandIndex: Int64 = processingStateRow[commandIndexColumn]
                
                let processingState: ObjectHistoryProcessingState?
                switch processingStateType {
                case 0: // ffwd
                    processingState = .fastForward(nextCommandIndex: Int(commandIndex))
                    
                case 1: // replay
                    processingState = .replay
                    
                default:
                    // Unknown
                    processingState = nil
                }
                
                if let processingState = processingState {
                    // If so, then fetch all the commands for it
                    
                    let commandsQuery = commandsTable.filter(objectIdColumn == identifier).order(timestampColumn.asc)
                    let commandsResult = try connection.prepare(commandsQuery)

                    let iterator = commandsResult.makeIterator()
                    var commands: [Command] = []
                    while let commandRow = iterator.next() {
                        let objectIdentifier: String = commandRow[objectIdColumn]
                        let commandIdentifier: String = commandRow[commandIdColumn]
                        let timestamp: Date = commandRow[timestampColumn]
                        let operation: Data = commandRow[operationColumn]
                        
                        let command = Command(objectIdentifier: objectIdentifier,
                                              commandIdentifier: commandIdentifier,
                                              timestamp: timestamp,
                                              operation: operation)
                        commands.append(command)
                    }
                    
                    let objectHistoryState = ObjectHistoryState(processingState: processingState, commands: commands)
                    return objectHistoryState
                }

            } else {
                // Couldn't find it, bail
                return nil
            }
        } catch {
            print("Error \(error)")
            return nil
        }
        
        return nil
    }
    
    func update(objectHistoryState: ObjectHistoryState, for identifier: String) {
        
        let processingStateType: Int64
        let commandIndex: Int64
        switch objectHistoryState.processingState {
        case .fastForward(let nextCommandIndex):
            processingStateType = 0
            commandIndex = Int64(nextCommandIndex)
            
        case .replay:
            processingStateType = 1
            commandIndex = 0
        }
        
        // Write to Processing States
        let insertProcessingState = processingStatesTable.insert(
            idColumn <- identifier,
            processingStateTypeColumn <- processingStateType,
            commandIndexColumn <- commandIndex)
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            // First delete old entry, if any exist
            let deleteProcessingStateQuery = processingStatesTable.filter(idColumn == identifier)
            try connection.run(deleteProcessingStateQuery.delete())
            
            let rowid = try connection.run(insertProcessingState)

            // Write to commands

            // First delete all old object commands (kind of inefficient...)
            let deleteCommandsQuery = commandsTable.filter(objectIdColumn == identifier)
            try connection.run(deleteCommandsQuery.delete())
            
            // Insert all new ones
            objectHistoryState.commands.forEach { command in
                
                let insertCommand = commandsTable.insert(
                    objectIdColumn <- command.objectIdentifier,
                    commandIdColumn <- command.commandIdentifier,
                    timestampColumn <- command.timestamp,
                    operationColumn <- command.operation
                )

                do {
                    let rowid = try connection.run(insertCommand)
                } catch {
                    print("Error inserting command \(error)")
                }
            }

        
        } catch {
            print("Error updating \(error)")
        }
        
        
    }

    func save(to folderUrl: URL) {
        // Flush out the sqlite connection and then copy the contents of the file to fileUrl, unless
        // they are the same path
        
        let fileUrl = folderUrl.appendingPathComponent(SqliteObjectHistoryStore.sqliteFilename)
        
        if databaseWriteUrl != fileUrl {
            try! FileManager.default.copyItem(at: databaseWriteUrl, to: fileUrl)
        }
    }
}
