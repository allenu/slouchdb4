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
    let connection: Connection

    let pendingUpdatesTable: Table
    let processingStatesTable: Table
    let objectDiffsTable: Table
    
//    let autoIdColumn = Expression<Int64>("autoId")
    let idColumn = Expression<String>("identifier")
    let processingStateTypeColumn = Expression<Int64>("type")
    let diffIndexColumn = Expression<Int64>("diffIndex")
    let diffTypeColumn = Expression<Int64>("diffType")
    let timestampColumn = Expression<Date>("timestamp")
    let objectTypeColumn = Expression<String?>("objectType")
    let jsonPropertiesColumn = Expression<String?>("jsonProperties")
    
    let databaseWriteUrl: URL

    // NOTE: url is meant to be a file path that we can constantly write to. It should not be
    // the Document bundle folder itself. Use a temporary folder and when it comes time to save
    // to the doc folder, use save(to:)
    init?(folderUrl: URL) {
        databaseWriteUrl = folderUrl.appendingPathComponent("object-history.sqlite3")
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
            // - ObjectDiffs -- database of diffs with primary key of objectIdentifier + timestamp
            pendingUpdatesTable = Table("PendingUpdates")
            processingStatesTable = Table("ProcessingStates")
            objectDiffsTable = Table("Diffs")
            
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
            t.column(diffIndexColumn)
        })
        
        try connection.run(objectDiffsTable.create { t in
//            t.column(autoIdColumn, primaryKey: true)
            t.column(idColumn)
            t.column(timestampColumn)
            t.column(diffTypeColumn)
            t.column(objectTypeColumn)
            t.column(jsonPropertiesColumn)
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
                let diffIndex: Int64 = processingStateRow[diffIndexColumn]
                
                let processingState: ObjectHistoryProcessingState?
                switch processingStateType {
                case 0: // ffwd
                    processingState = .fastForward(nextDiffIndex: Int(diffIndex))
                    
                case 1: // replay
                    processingState = .replay
                    
                default:
                    // Unknown
                    processingState = nil
                }
                
                if let processingState = processingState {
                    // If so, then fetch all the diffs for it
                    
                    let objectDiffsQuery = objectDiffsTable.filter(idColumn == identifier).order(timestampColumn.asc)
                    let objectDiffsResult = try connection.prepare(objectDiffsQuery)

                    let iterator = objectDiffsResult.makeIterator()
                    var objectDiffs: [ObjectDiff] = []
                    while let diffRow = iterator.next() {
                        let diffType: Int64 = diffRow[diffTypeColumn]
                        let objectType: String? = diffRow[objectTypeColumn]
                        let timestamp: Date = diffRow[timestampColumn]
                        let jsonProperties: String? = diffRow[jsonPropertiesColumn]
                        
                        let properties: [String : JSONValue]?
                        if let jsonProperties = jsonProperties,
                            let data = jsonProperties.data(using: .utf8) {
                            properties = try? decoder.decode([String : JSONValue].self, from: data)
                        } else {
                            properties = nil
                        }
                        
                        switch diffType {
                        case 0: // insert
                            if let properties = properties, let objectType = objectType {
                                let object = DatabaseObject(type: objectType, properties: properties)
                                objectDiffs.append(.insert(identifier: identifier, timestamp: timestamp, object: object))
                            } else {
                                assertionFailure("Unrecognized data")
                            }
                            
                        case 1: // update
                            if let properties = properties {
                                assert(objectType == nil)
                                
                                objectDiffs.append(.update(identifier: identifier, timestamp: timestamp, properties: properties))
                            } else {
                                assertionFailure("Unrecognized data")
                            }

                        case 2: // delete
                            objectDiffs.append(.remove(identifier: identifier, timestamp: timestamp))
                            
                        default:
                            assertionFailure("Unrecognized diffType")
                            return nil
                        }
                    }
                    
                    let objectHistoryState = ObjectHistoryState(processingState: processingState, diffs: objectDiffs)
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
        let diffIndex: Int64
        switch objectHistoryState.processingState {
        case .fastForward(let nextDiffIndex):
            processingStateType = 0
            diffIndex = Int64(nextDiffIndex)
            
        case .replay:
            processingStateType = 1
            diffIndex = 0
        }
        
        // Write to Processing States
        let insertProcessingState = processingStatesTable.insert(
            idColumn <- identifier,
            processingStateTypeColumn <- processingStateType,
            diffIndexColumn <- diffIndex)
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            // First delete old entry, if any exist
            let deleteProcessingStateQuery = processingStatesTable.filter(idColumn == identifier)
            try connection.run(deleteProcessingStateQuery.delete())
            
            let rowid = try connection.run(insertProcessingState)

            // Write to ObjectDiffs

            // First delete all old object diffs (kind of inefficient...)
            let deleteObjectDiffsQuery = objectDiffsTable.filter(idColumn == identifier)
            try connection.run(deleteObjectDiffsQuery.delete())
            
            // Insert all new ones
            objectHistoryState.diffs.forEach { diff in
                
                let insertCommand: SQLite.Insert
                switch diff {
                case .insert(let identifier, let timestamp, let object):
                    let data = try! encoder.encode(object.properties)
                    let jsonPropertiesString: String = String(data: data, encoding: .utf8)!
                    insertCommand = objectDiffsTable.insert(
                        idColumn <- identifier,
                        timestampColumn <- timestamp,
                        diffTypeColumn <- 0,
                        objectTypeColumn <- object.type,
                        jsonPropertiesColumn <- jsonPropertiesString
                    )

                case .update(let identifier, let timestamp, let properties):
                    let data = try! encoder.encode(properties)
                    let jsonPropertiesString: String = String(data: data, encoding: .utf8)!
                    insertCommand = objectDiffsTable.insert(
                        idColumn <- identifier,
                        timestampColumn <- timestamp,
                        diffTypeColumn <- 1,
                        jsonPropertiesColumn <- jsonPropertiesString
                    )

                case .remove(let identifier, let timestamp):
                    insertCommand = objectDiffsTable.insert(
                        idColumn <- identifier,
                        timestampColumn <- timestamp,
                        diffTypeColumn <- 2
                    )
                }
                
                do {
                    let rowid = try connection.run(insertCommand)
                } catch {
                    print("Error inserting objectDiff \(error)")
                }
            }

        
        } catch {
            print("Error updating \(error)")
        }
        
        
    }

    func save(to folderUrl: URL) {
        // Flush out the sqlite connection and then copy the contents of the file to fileUrl, unless
        // they are the same path
        
        let fileUrl = folderUrl.appendingPathComponent("object-history.sqlite3")
        
        if databaseWriteUrl != fileUrl {
            try! FileManager.default.copyItem(at: databaseWriteUrl, to: fileUrl)
        }
    }
}
