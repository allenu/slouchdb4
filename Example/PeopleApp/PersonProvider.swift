//
//  PersonProvider.swift
//  PeopleApp
//
//  Created by Allen Ussher on 3/5/20.
//  Copyright © 2020 CocoaPods. All rights reserved.
//

import Foundation
import SQLite
import SlouchDB4

class PersonProvider {
    static let sqliteFilename = "people-app.sqlite3"
    static let dataDidChangeNotification = NSNotification.Name("DatabaseManagerDataDidChange")
    static let dataDidReloadNotification = NSNotification.Name("DatabaseManagerDataDidReload")

    static func databaseFileExists(folderUrl: URL) -> Bool {
        let databaseFileUrl = folderUrl.appendingPathComponent(sqliteFilename)
        return FileManager.default.fileExists(atPath: databaseFileUrl.path)
    }
    
    static func copyDatabaseFile(from sourceUrl: URL, to destinationUrl: URL) {
        let sourceFileUrl = sourceUrl.appendingPathComponent(PersonProvider.sqliteFilename)
        let destinationFileUrl = destinationUrl.appendingPathComponent(PersonProvider.sqliteFilename)
        
        // Remove file at destination if it's already there
        if FileManager.default.fileExists(atPath: destinationFileUrl.path) {
            try! FileManager.default.removeItem(at: destinationFileUrl)
        }
        
        try! FileManager.default.copyItem(at: sourceFileUrl, to: destinationFileUrl)
    }
    
    let connection: Connection
    let peopleTable: Table

    let idColumn = Expression<String>("identifier")
    let nameColumn = Expression<String>("name")
    let weightColumn = Expression<Int64>("weight")
    let ageColumn = Expression<Int64>("age")
    
    let databaseWriteUrl: URL

    
    var currentQuery: QueryType {
        if let searchFilter = searchFilter {
            return peopleTable.filter(nameColumn.like("%\(searchFilter)%"))
        } else {
            return peopleTable
        }
    }
    
    var searchFilter: String? {
        didSet {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: PersonProvider.dataDidReloadNotification, object: self)
            }
        }
    }

    
    init?(folderUrl: URL) {
        databaseWriteUrl = folderUrl.appendingPathComponent("people-app.sqlite3")
        var connection: Connection?
        do {
            connection = try Connection(databaseWriteUrl.path)
        } catch {
            connection = nil
        }
        
        print("PersonProvider writing files to \(databaseWriteUrl.path)")

        if let connection = connection {
            self.connection = connection
            
            peopleTable = Table("People")
            
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
        try connection.run(peopleTable.create { t in
            t.column(idColumn, primaryKey: true)
            t.column(nameColumn)
            t.column(weightColumn)
            t.column(ageColumn)
        })
    }
    
    public func save(to folderUrl: URL) {
        let fileUrl = folderUrl.appendingPathComponent("people-app.sqlite3")
        
        if databaseWriteUrl != fileUrl {
            // TODO: delete fileUrl first ?
            
//            connection = nil
            
            print("PeopleProvider saving to \(fileUrl.path)")
            try! FileManager.default.copyItem(at: databaseWriteUrl, to: fileUrl)
        }
    }
    
    func searchFilterContains(person: Person) -> Bool {
        if let searchFilter = searchFilter {
            if searchFilter.isEmpty {
                return true
            } else {
                return person.name.lowercased().contains(searchFilter.lowercased())
            }
        } else {
            return true
        }
    }
    
    func person(for identifier: String) -> Person? {
        let query = peopleTable.filter(idColumn == identifier)
        do {
            let result = try connection.prepare(query)
            if let personRow = result.makeIterator().next() {
                let person = Person(identifier: personRow[idColumn],
                                    name: personRow[nameColumn],
                                    weight: Int(personRow[weightColumn]),
                                    age: Int(personRow[ageColumn]))
                return person
            } else {
                print("Error fetching person row \(identifier)")
            }
        } catch {
            print("Error loading person \(identifier)")
        }
        
        return nil
    }
}

extension PersonProvider {
    public func apply(mergeResult: MergeResult) {
        if mergeResult.totalChanges > 0 {
            
            // Apply the changes
            mergeResult.insertedObjects.forEach { identifier, person in
                insert(person: person)
            }

            mergeResult.updatedObjects.forEach { identifier, person in
                update(person: person)
            }
            
            mergeResult.removedObjects.forEach { identifier in
                removePerson(identifier: identifier)
            }
            
            var userInfo: [String : [String] ] = [:]

            if mergeResult.insertedObjects.count > 0 {
                let insertedIdentifiers = mergeResult.insertedObjects.map { $0.key }
                userInfo["insertedIdentifiers"] = insertedIdentifiers
            }
            if mergeResult.updatedObjects.count > 0 {
                let updatedIdentifiers = mergeResult.updatedObjects.map { $0.key }
                userInfo["updatedIdentifiers"] = updatedIdentifiers
            }
            if mergeResult.removedObjects.count > 0 {
                let removedIdentifiers = mergeResult.removedObjects
                userInfo["removedIdentifiers"] = removedIdentifiers
            }

            NotificationCenter.default.post(name: PersonProvider.dataDidChangeNotification, object: self, userInfo: userInfo)
        }
    }
    
    func insert(person: Person) {
        let insert = peopleTable.insert(
            idColumn <- person.identifier,
            nameColumn <- person.name,
            weightColumn <- Int64(person.weight),
            ageColumn <- Int64(person.age))
        
        do {
            let rowid = try connection.run(insert)
//            print("inserted row \(rowid)")
            
            // Announce it
            DispatchQueue.main.async {
                let insertedIdentifiers: [String] = [ person.identifier ]
            }
        } catch {
            print("Failed to insert person with identifier \(person.identifier) -- may already exist? error: \(error)")
        }
    }

    func update(person: Person) {
        let update = peopleTable.update(
            idColumn <- person.identifier,
            nameColumn <- person.name,
            weightColumn <- Int64(person.weight),
            ageColumn <- Int64(person.age))
        
        do {
            let rowid = try connection.run(update)
        } catch {
            print("Failed to update person with identifier \(person.identifier) -- may already exist? error: \(error)")
        }
    }

    func removePerson(identifier: String) {
        let deleteFilter = peopleTable.filter(idColumn == identifier)

        do {
            if try connection.run(deleteFilter.delete()) > 0 {
            } else {
                print("no items found")
            }
        } catch {
            print("delete failed: \(error)")
        }
    }
}

extension PersonProvider: CacheWindowItemProvider {
    typealias ItemType = Person

    func queryContains(item: Person) -> Bool {
        return searchFilterContains(person: item)
    }
    
    func item(for identifier: IdentifierType) -> Person? {
        return person(for: identifier)
    }
    
    func itemsBefore(identifier: IdentifierType?, limit: Int) -> [IdentifierType] {
        let query: QueryType
        
        if let identifier = identifier {
            query = currentQuery.filter(idColumn < identifier).order(idColumn.desc).limit(limit)
        } else {
            query = currentQuery.order(idColumn.desc).limit(limit)
        }
        var prependedIdentifiers: [String] = []
        do {
            let result = try connection.prepare(query)
            // Insert in reverse order by inserting each item at 0
            while let personRow = result.makeIterator().next() {
                prependedIdentifiers.insert(personRow[idColumn], at: 0)
            }
        } catch {
            print("Error loading person row")
        }
        return prependedIdentifiers
    }
    
    func itemsAfter(identifier: IdentifierType?, limit: Int) -> [IdentifierType] {
        let query: QueryType
        
        if let identifier = identifier {
            query = currentQuery.filter(idColumn > identifier).order(idColumn.asc).limit(limit)
        } else {
            // We don't have any entries at all yet... so just search for ALL items
            query = currentQuery.order(idColumn.asc).limit(limit)
        }

        var appendedIdentifiers: [String] = []
        do {
            let result = try connection.prepare(query)
            while let personRow = result.makeIterator().next() {
                appendedIdentifiers.append(personRow[idColumn])
            }
        } catch {
            print("Error loading person row")
        }
        return appendedIdentifiers
    }
    
    func items(at index: Int, limit: Int) -> [IdentifierType] {
        // Try to fetch items there
        let query = currentQuery.order(idColumn.asc).limit(limit, offset: index)
        var newIdentifiers: [String] = []
        do {
            let result = try connection.prepare(query)
            while let personRow = result.makeIterator().next() {
                newIdentifiers.append(personRow[idColumn])
            }
        } catch {
            print("Error loading person row")
        }
        return newIdentifiers
    }
}
