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
    var session: Session
    
    var numEntries: Int = 1

    override init() {
        // Add your subclass-specific initialization here.
        let localIdentifier = UUID().uuidString // TODO: ???
        
        let tracker = ObjectHistoryTracker()
        let objectCache = InMemObjectCache()
        let database = Database(objectCache: objectCache, objectHistoryTracker: tracker, sortedIdentifiers: [])
        
        let journalFileManager = JournalFileManager()
        let remoteFileStore = RemoteFileStore()
        let storedState = JournalManagerStoredState(localIdentifier: localIdentifier, journalByteOffsets: [:], remoteFileVersion: [:], lastLocalVersionPushed: "none")
        let journalManager = JournalManager(journalFileManager: journalFileManager, remoteFileStore: remoteFileStore, storedState: storedState)

        session = Session(database: database, journalManager: journalManager)

// TODO:
        /*
        let database = Database(objectCache: ObjectCache())
        session = Session(localIdentifier: localIdentifier, database: database)
 */

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
    
    override func write(to url: URL, ofType typeName: String) throws {
        session.save(to: url)
    }
    
    override func read(from url: URL, ofType typeName: String) throws {
        if let session = Session.create(from: url) {
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
       let now = Date()
        numEntries = numEntries + 1
    // TODO:
//       let diffs: [JournalDiff] = [
//           JournalDiff(diffType: .insert,
//                       objectType: "person",
//                       identifier: person.identifier,
//                       timestamp: now,
//                       properties: properties)
//       ]
//       let object = CreateDatabaseObject(from: diffs)!
//       let objectState = ObjectState(identifier: person.identifier,
//                                     diffs: diffs,
//                                     object: object)
//       session.insert(objectState)
    
       self.updateChangeCount(.changeDone)
   }
   
   func remove(person: Person) {
//       session.remove(identifier: person.identifier)
   }
   
   var people: [Person] {

    // TODO:
//       let fetchResults = session.fetch(of: "person")
//       let objectStates = fetchResults.results
//
//       return objectStates.map { objectState in
//           let name: String
//           let age: Int
//           let weight: Int
//
//           if let nameProperty = objectState.object.properties[Person.namePropertyKey],
//               case let JSONValue.string(value) = nameProperty {
//               name = value
//           } else {
//               name = "Unnamed"
//           }
//
//           if let ageProperty = objectState.object.properties[Person.agePropertyKey],
//               case let JSONValue.int(value) = ageProperty {
//               age = value
//           } else {
//               age = 0
//           }
//
//           if let weightProperty = objectState.object.properties[Person.weightPropertyKey],
//               case let JSONValue.int(value) = weightProperty {
//               weight = value
//           } else {
//               weight = 0
//           }
//
//           return Person(identifier: objectState.identifier,
//                         name: name,
//                         weight: weight,
//                         age: age)
//       }
    
    let persons = Array(0..<numEntries).map { index in
        return Person(identifier: "\(index)", name: "John \(index)", weight: index + 100, age: index + 30)
    }
    
    return persons
   }

   func modifyPerson(identifier: String, properties: [String : JSONValue]) {
    // TODO:
//       session.update(identifier: identifier, properties: properties)
       
       self.updateChangeCount(.changeDone)
   }
   
   func syncNew(remoteFolderUrl: URL) {
       /*
       let remoteSessionStore = FileBasedRemoteSessionStore(remoteFolderUrl: remoteFolderUrl)
       session.sync(remoteSessionStore: remoteSessionStore, completionHandler: { response in
           switch response {
           case .success:
               Swift.print("Sync successful")
               self.updateChangeCount(.changeDone)
               
           case .failure(let reason):
               Swift.print("Sync failed: \(reason)")
           }
       })
*/
   }

}

