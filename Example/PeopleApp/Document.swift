//
//  Document.swift
//  PeopleApp
//
//  Created by Allen Ussher on 2/1/20.
//  Copyright © 2020 CocoaPods. All rights reserved.
//

import Cocoa
import SlouchDB4

class Document: NSDocument {
    var changeTracker: ChangeTracker
    
    var fileSystemRemoteFileStore: FileSystemRemoteFileStore
    let journalFileManager: JournalFileManager
//    var objectStore = InMemObjectStore()
    
    var personProvider: PersonProvider
    
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
        changeTracker.dataSource = self
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
                    let journalManager = JournalManager.create(from: url, with: remoteFileStore) {
                    let changeTracker = ChangeTracker(journalManager: journalManager, objectHistoryStore: objectHistoryStore)

                    self.changeTracker = changeTracker
                    self.changeTracker.delegate = self
                    self.changeTracker.dataSource = self
                    
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
        let properties: [String : JSONValue] = [
            Person.namePropertyKey : .string(person.name),
            Person.agePropertyKey : .int(person.age),
            Person.weightPropertyKey : .int(person.weight)
        ]
        changeTracker.insert(identifier: UUID().uuidString, object: DatabaseObject(type: "person", properties: properties))
        self.updateChangeCount(.changeDone)
    }
   
    func remove(person: Person) {
       changeTracker.remove(identifier: person.identifier)
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
        
        changeTracker.sync(completion: { response in
            switch response {
            case .success:
                self.updateChangeCount(.changeDone)
                
            case .failure:
                break
            }
            completion(response)
        }, partialResults: partialResults)
   }
}

extension Document: ChangeTrackerDelegate {
    func changeTracker(_ changeTracker: ChangeTracker, didRequestMerge mergeResult: MergeResult) {
//        objectStore.apply(mergeResult: mergeResult)
        personProvider.apply(mergeResult: mergeResult)
    }
}

extension Document: ChangeTrackerDataSource {
    func changeTracker(_ changeTracker: ChangeTracker, objectFor identifier: String) -> DatabaseObject? {
//        return objectStore.fetch(identifier: identifier)

        if let person = personProvider.person(for: identifier) {
            let properties: [String : JSONValue] = [
                Person.namePropertyKey : .string(person.name),
                Person.agePropertyKey : .int(person.age),
                Person.weightPropertyKey : .int(person.weight)
            ]
            let object = DatabaseObject(type: "person", properties: properties)
            return object
        } else {
            return nil
        }
    }
}
