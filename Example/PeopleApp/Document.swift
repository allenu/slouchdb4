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
    override var fileURL: URL? {
        didSet {
            if let fileURL = fileURL {
                journalFileManager.rootFolderUrl = fileURL
            }
        }
    }
    var session: Session
    
    var numEntries: Int = 1
    var fileSystemRemoteFileStore: FileSystemRemoteFileStore
    let journalFileManager: JournalFileManager
    
    override init() {
        // Add your subclass-specific initialization here.
        let localIdentifier = UUID().uuidString // TODO: ???
        
        let tracker = ObjectHistoryTracker()
        let objectCache = InMemObjectCache()
        let database = Database(objectCache: objectCache, objectHistoryTracker: tracker, sortedIdentifiers: [])
        
        let directory = NSTemporaryDirectory()
        let pathName = NSUUID().uuidString
        let tempUrl = NSURL.fileURL(withPathComponents: [directory, pathName])!

        journalFileManager = JournalFileManager(rootFolderUrl: tempUrl)
        fileSystemRemoteFileStore = FileSystemRemoteFileStore(rootFolderUrl: tempUrl)
        let remoteFileStore = fileSystemRemoteFileStore
        let storedState = JournalManagerStoredState(localIdentifier: localIdentifier, journalByteOffsets: [:], remoteFileVersion: [:], lastLocalVersionPushed: "none")
        let journalManager = JournalManager(journalFileManager: journalFileManager, remoteFileStore: remoteFileStore, storedState: storedState)

        session = Session(database: database, journalManager: journalManager)

        super.init()
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
        
        let allowSave: Bool
        switch saveOperation {
        case .saveAsOperation, .saveOperation, .saveToOperation:
            allowSave = true
            
        case .autosaveAsOperation, .autosaveElsewhereOperation, .autosaveInPlaceOperation:
            allowSave = false
        @unknown default:
            allowSave = false
        }
        
        if allowSave {
            // Create folder if not exists
            if !FileManager.default.fileExists(atPath: url.path) {
                try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            }
            
            session.save(to: url)
        } else {
            throw NSError(domain: "com.ussherpress", code: 1, userInfo: [:])

        }
    }
    
    override func read(from url: URL, ofType typeName: String) throws {
        fileSystemRemoteFileStore = FileSystemRemoteFileStore(rootFolderUrl: url)
        let remoteFileStore = fileSystemRemoteFileStore
        if let session = Session.create(from: url, with: remoteFileStore) {
            self.session = session
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
        session.insert(identifier: UUID().uuidString, object: DatabaseObject(type: "person", properties: properties))
        self.updateChangeCount(.changeDone)
    }
   
    func remove(person: Person) {
       session.remove(identifier: person.identifier)
    }
   
    var people: [Person] {
        let fetchResults = session.fetch(of: "person")
        let objectStates = fetchResults.results

        return objectStates.map { fetchedObject in
            let name: String
            let age: Int
            let weight: Int

            if let nameProperty = fetchedObject.object.properties[Person.namePropertyKey],
                case let JSONValue.string(value) = nameProperty {
                name = value
            } else {
                name = "Unnamed"
            }

            if let ageProperty = fetchedObject.object.properties[Person.agePropertyKey],
                case let JSONValue.int(value) = ageProperty {
                age = value
            } else {
                age = 0
            }

            if let weightProperty = fetchedObject.object.properties[Person.weightPropertyKey],
                case let JSONValue.int(value) = weightProperty {
                weight = value
            } else {
                weight = 0
            }

            return Person(identifier: fetchedObject.identifier,
                          name: name,
                          weight: weight,
                          age: age)
        }
    }

    func modifyPerson(identifier: String, properties: [String : JSONValue]) {
        session.update(identifier: identifier, updatedProperties: properties)
       
        self.updateChangeCount(.changeDone)
    }
   
    func syncNew(remoteFolderUrl: URL,
                 completion: @escaping (SessionSyncResponse) -> Void,
                 partialResults: @escaping (Double) -> Void) {
        fileSystemRemoteFileStore.remoteFolderUrl = remoteFolderUrl
        
        session.sync(completion: { response in
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

