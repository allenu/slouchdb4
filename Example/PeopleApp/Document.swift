//
//  Document.swift
//  PeopleApp
//
//  Created by Allen Ussher on 2/1/20.
//  Copyright © 2020 CocoaPods. All rights reserved.
//

import Cocoa
import SlouchDB4

struct PersonDbOperation: Codable {
    let type: String
    let data: Data?
}

class Document: NSDocument {
    var changeTracker: ChangeTracker
    
    var fileSystemRemoteFileStore: FileSystemRemoteFileStore
    let journalFileManager: JournalFileManager
//    var objectStore = InMemObjectStore()
    
    var personProvider: PersonProvider
    
    var bulkModeCount: Int = 0
    var bulkInsertedObjects: [String : Person] = [:]
    var bulkUpdatedObjects: [String : Person] = [:]
    var bulkRemovedObjects: [String] = []

    
    override init() {
        // Add your subclass-specific initialization here.
        let localIdentifier = UUID().uuidString // TODO: ???
        
        let directory = NSTemporaryDirectory()
        let subpath = UUID().uuidString
        let tempUrl = NSURL.fileURL(withPathComponents: [directory, subpath])!
        
        try! FileManager.default.createDirectory(at: tempUrl, withIntermediateDirectories: true, attributes: nil)

        // let objectHistoryStore = InMemObjectHistoryStore()
        let objectHistoryStore = SqliteObjectHistoryStore(folderUrl: tempUrl)
        personProvider = PersonProvider(folderUrl: tempUrl)!

        journalFileManager = JournalFileManager(workingFolderUrl: tempUrl)
        fileSystemRemoteFileStore = FileSystemRemoteFileStore()
        let remoteFileStore = fileSystemRemoteFileStore
        let storedState = JournalManagerStoredState(localIdentifier: localIdentifier, journalByteOffsets: [:], remoteFileVersion: [:], lastLocalVersionPushed: "none")
        let journalManager = JournalManager(journalFileManager: journalFileManager, remoteFileStore: remoteFileStore, storedState: storedState)

        changeTracker = ChangeTracker(journalManager: journalManager, objectHistoryStore: objectHistoryStore!)

        super.init()

        changeTracker.delegate = self
    }

    override class var autosavesInPlace: Bool {
        return true
    }

    override func makeWindowControllers() {
        // Returns the Storyboard that contains your Document window.
        let storyboard = NSStoryboard(name: NSStoryboard.Name("Main"), bundle: nil)
        let windowController = storyboard.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier("Document Window Controller")) as! NSWindowController
        self.addWindowController(windowController)
    }
    
    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        
        // Create folder if not exists
        if !FileManager.default.fileExists(atPath: url.path) {
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
        
        changeTracker.save(to: url)
//        objectStore.save(to: url)
        personProvider.save(to: url)
        
        Swift.print("write(to:) is done")
    }
    
    override func read(from url: URL, ofType typeName: String) throws {
        fileSystemRemoteFileStore = FileSystemRemoteFileStore()
        let remoteFileStore = fileSystemRemoteFileStore
        
        if SqliteObjectHistoryStore.objectHistoryStoreExists(folderUrl: url) {
            let directory = NSTemporaryDirectory()
            let subpath = UUID().uuidString
            let tempFolderUrl = NSURL.fileURL(withPathComponents: [directory, subpath])!
            try! FileManager.default.createDirectory(at: tempFolderUrl, withIntermediateDirectories: true, attributes: nil)

            // Make copy of sqlite database in temp folder
            SqliteObjectHistoryStore.copyObjectHistoryStore(from: url, to: tempFolderUrl)
            
            if PersonProvider.databaseFileExists(folderUrl: url) {
                PersonProvider.copyDatabaseFile(from: url, to: tempFolderUrl)
                
                //if let objectHistoryStore = InMemObjectHistoryStore.create(from: url),
                if let objectHistoryStore = SqliteObjectHistoryStore(folderUrl: tempFolderUrl),
                    let journalManager = JournalManager.create(from: url,
                                                               useTempWorkingFolder: true,
                                                               with: remoteFileStore) {
                    let changeTracker = ChangeTracker(journalManager: journalManager, objectHistoryStore: objectHistoryStore)

                    self.changeTracker = changeTracker
                    self.changeTracker.delegate = self
                    
                    if let personProvider = PersonProvider(folderUrl: tempFolderUrl) {
                        self.personProvider = personProvider
                    }
    //                if let objectStore = InMemObjectStore.create(from: url) {
    //                    self.objectStore = objectStore
    //                }
                } else {
                    // Missing People database
                    throw NSError(domain: "com.ussherpress", code: 1, userInfo: [:])
                }
            

            } else {
                throw NSError(domain: "com.ussherpress", code: 1, userInfo: [:])
            }
        } else {
            throw NSError(domain: "com.ussherpress", code: 1, userInfo: [:])
        }
    }

    // Person stuff
    func add(person: Person) {
        let encoder = JSONEncoder()
        let personData = try! encoder.encode(person)
        let personDbOperation = PersonDbOperation(type: "insert", data: personData)
        let data = try! encoder.encode(personDbOperation)
        
        let command = Command(objectIdentifier: person.identifier,
                              commandIdentifier: UUID().uuidString,
                              timestamp: Date(),
                              operation: data)
        changeTracker.append(command: command)
        
        self.updateChangeCount(.changeDone)
    }
   
    func remove(person: Person) {
        let encoder = JSONEncoder()
        let personDbOperation = PersonDbOperation(type: "remove", data: nil)
        let data = try! encoder.encode(personDbOperation)
        
        let command = Command(objectIdentifier: person.identifier,
                              commandIdentifier: UUID().uuidString,
                              timestamp: Date(), operation: data)
        changeTracker.append(command: command)
    }
    
    func startBulkMode() {
        DispatchQueue.main.async {
            Swift.print("startBulkMode")
            self.bulkModeCount = self.bulkModeCount + 1
        }
    }
    
    func endBulkMode() {
        DispatchQueue.main.async {
            Swift.print("endBulkMode")
            self.bulkModeCount = self.bulkModeCount - 1
            
            if self.bulkModeCount == 0 {
                self.processBulkItems()
            }
        }
    }
    
    func processBulkItems() {
        Swift.print("processBulkItems")
        let mergeResult = MergeResult(insertedObjects: bulkInsertedObjects,
                                      removedObjects: bulkRemovedObjects,
                                      updatedObjects: bulkUpdatedObjects)
        
        personProvider.apply(mergeResult: mergeResult)
        
        bulkRemovedObjects = []
        bulkInsertedObjects = [:]
        bulkUpdatedObjects = [:]
    }

    /*
    var people: [Person] {
        let fetchResults = objectStore.fetch(of: "person")
        let objectStates = fetchResults.results

        return objectStates.map { Person.create(from: $0.identifier, databaseObject: $0.object) }
    }

    func modifyPerson(identifier: String, properties: [String : JSONValue]) {
        changeTracker.update(identifier: identifier, updatedProperties: properties)
       
        self.updateChangeCount(.changeDone)
    }
   
    func fetch(of type: String?, limitCount: Int, predicate: ((FetchedDatabaseObject) -> Bool)?) -> FetchResult {
        return objectStore.fetch(of: type, limitCount: limitCount, predicate: predicate)
    }
 */
    
    func syncNew(remoteFolderUrl: URL,
                 completion: @escaping (ChangeTracker.SyncResponse) -> Void,
                 partialResults: @escaping (Double) -> Void) {
        fileSystemRemoteFileStore.remoteFolderUrl = remoteFolderUrl
        
        startBulkMode()
        changeTracker.sync(completion: { response in
            DispatchQueue.main.async {
                switch response {
                case .success:
                    self.updateChangeCount(.changeDone)
                    
                case .failure:
                    break
                }
                self.endBulkMode()
            
                completion(response)
            }
        }, partialResults: partialResults)
   }
}

extension Document: ChangeTrackerDelegate {
    func changeTracker(_ changeTracker: ChangeTracker,
                       requestsExecute commands: [Command],
                       for identifier: String,
                       startingAt playbackPosition: PlaybackPosition,
                       completion: @escaping (Bool) -> Void) {

        let decoder = JSONDecoder()
        
        var basePerson: Person?
        switch playbackPosition {
        case .start:
            // This means we must construct a new object at some point
            basePerson = nil
            
        case .currentPosition:
            // This means we MUST have an object already...
            let existingPerson = personProvider.person(for: identifier)
            if existingPerson == nil {
                // Problem! Cannot update a person that doesn't exist yet
                DispatchQueue.main.async {
                    completion(false)
                }
            }
            basePerson = existingPerson
        }

        // TODO: Process each command before doing bulk insert/remove/etc
        // i.e. if got "insert"
        // - see if existing item. if so, pendingDelete = true
        // if "update",
        // - look up updated entry so far and modify it
        // if "remove"
        // - pendingDelete = true
        // when get to end of commands, then go through each item
        
        var wasRemoved = false
        var wasInserted = false
        var encounteredError = false
        
        commands.forEach { command in
            guard !encounteredError else { return }
            
            if let operation = try? decoder.decode(PersonDbOperation.self, from: command.operation) {
                Swift.print("found operation: \(operation.type) \(command.commandIdentifier)")
                
                switch operation.type {
                case "insert":
                    if wasRemoved {
                        // Can't insert after remove
                        encounteredError = true
                        assertionFailure()
                    } else {
                        if basePerson != nil {
                            // Bad data! Why are we inserting an existing entry?
                            
                            assertionFailure()
                        } else {
                            if let data = operation.data,
                                let person = try? decoder.decode(Person.self, from: data) {
                                basePerson = person
                                wasInserted = true
                            } else {
                                assertionFailure()
                            }
                        }
                    }
                    
                case "remove":
                    wasRemoved = true
                    basePerson = nil
                    
                case "update":
                    if wasRemoved {
                        // Can't update after remove
                        encounteredError = true
                        assertionFailure()
                    } else if let person = basePerson {
                        // TODO:
                        // This depends on how we encode "update person"
                        
                    } else {
                        // Must mean we have an incomplete set of commands
                        encounteredError = true
                        assertionFailure()
                    }
                    
                default:
                    // Don't understand command
                    encounteredError = true
                    assertionFailure()
                }
                
            } else {
                // Don't understand command
                encounteredError = true
                assertionFailure()
            }
        }
        
        if !encounteredError {
            if let basePerson = basePerson {
                if wasInserted {
                    bulkInsertedObjects[identifier] = basePerson
                } else {
                    bulkUpdatedObjects[identifier] = basePerson
                }
            } else {
                if wasRemoved {
                    bulkRemovedObjects.append(identifier)
                } else {
                    // Unknown
                    assertionFailure()
                }
            }
        }
        
        DispatchQueue.main.async {
            if self.bulkModeCount == 0 {
                self.processBulkItems()
            }
            completion(!encounteredError)
        }
    }
}
