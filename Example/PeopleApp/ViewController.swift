//
//  ViewController.swift
//  PeopleApp
//
//  Created by Allen Ussher on 2/1/20.
//  Copyright © 2020 CocoaPods. All rights reserved.
//

import Cocoa

enum TableViewSourceDataType {
    case all
    case filteredResults(searchText: String, people: [Person])
}

class ViewController: NSViewController {
    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var identifierLabel: NSTextField!
    @IBOutlet weak var folderButton: NSButton!
    @IBOutlet weak var searchField: NSTextField!
    var nextSearchTime: Date?
    var isSearching = false // TODO: Don't need this if we have contextId
    var sourceDataType: TableViewSourceDataType = .all

    private var _document: Document?
    var document: Document? {
        get {
            if _document == nil {
                _document = self.view.window?.windowController?.document as? Document
            }
            return _document
        }
    }
    var remoteFolder: URL?
    var searchContextId: Int = 0

    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        tableView.dataSource = self
        tableView.delegate = self
        
        searchField.delegate = self
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        
        identifierLabel.stringValue = document?.changeTracker.localIdentifier ?? "unknown"
        tableView.reloadData()
    }
    
    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    
    @IBAction func didTapAddPerson(sender: Any) {
        guard let document = document else { return }
        
        let randomNames = ["Alice", "Bob", "Carol", "Eve", "Frank"]
        let name = randomNames[ Int(arc4random()) % randomNames.count ]
        let weight = Int(arc4random() % 100) + 100
        let age = Int(arc4random() % 30) + 10
        
        let person = Person(identifier: UUID().uuidString, name: name, weight: weight, age: age)
        document.add(person: person)
        
        // TODO: This is super inefficient
        tableView.reloadData()
    }

    @IBAction func didTapSync(sender: Any) {
        guard let document = document else { return }
        
        if let remoteFolder = remoteFolder {
            document.syncNew(remoteFolderUrl: remoteFolder, completion: { response in
                switch response {
                case .success:
                    Swift.print("Sync successful")
                    
                case .failure:
                    Swift.print("Sync failed: ")
                }
                
                switch self.sourceDataType {
                case .all:
                    self.tableView.reloadData()
                    
                case .filteredResults(let searchText, _):
                    // Rerun search
                    self.search(text: searchText)
                }
            }, partialResults: { percent in
                
            })
            
        }
    }

    @IBAction func didTapSyncLocation(sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.begin(completionHandler: { result in
            if result == NSApplication.ModalResponse.OK {
                
                let remoteURL = openPanel.urls.first
                self.remoteFolder = remoteURL
                
                DispatchQueue.main.async {
                    self.folderButton.title = remoteURL?.path ?? "Select Sync Folder"
                }
            }
        })
    }
    
    @IBAction func didTapDelete(sender: Any) {
        guard let document = document else { return }
        
        let people: [Person]
        switch sourceDataType {
        case .all:
            people = document.people
            
        case .filteredResults(_, let filteredResults):
            people = filteredResults
        }

        let selectedRow = tableView.selectedRow
        if selectedRow >= 0 && selectedRow < people.count {

            // Update the UI first
            tableView.beginUpdates()
            let rows = IndexSet(integer: selectedRow)
            tableView.removeRows(at: rows, withAnimation: .slideUp)
            tableView.endUpdates()

            // Then the data
            let person = people[selectedRow]
            document.remove(person: person)
        }
    }
    
    func search(text: String) {
        guard let document = document else { return }
        guard !isSearching else { return }

        if text.isEmpty {
            sourceDataType = .all
            tableView.reloadData()
        } else {
            // Only execute a search some delta after you've finished typing to allow
            // you to type a bunch first.
            let searchStartDelta: TimeInterval = 0.1
            nextSearchTime = Date().addingTimeInterval(searchStartDelta)
            
            // Keep track of this search so that we don't bother getting results if a new search by the user
            // is created while we're fetching an old one.
            searchContextId = searchContextId + 1
            let thisSearchContextId = searchContextId
            
            DispatchQueue.main.asyncAfter(deadline: .now() + searchStartDelta, execute: {
                guard let nextSearchTime = self.nextSearchTime else { return }
                
                // NOTE: Something may have come along and bumped nextSearchTime
                // ahead, so need to check first if we've passed it.
                let now = Date()
                if now >= nextSearchTime {
                    self.nextSearchTime = nil
                    self.isSearching = true
                    
                    // Do search now
                    print("Searching \(text)")
                    
                    // Do search in background since it might take a while
                    DispatchQueue.global(qos: .userInitiated).async {
                            
                        let results = document.fetch(of: "person", limitCount: 100, predicate: { fetchedObject in
                            let person = Person.create(from: fetchedObject.identifier, databaseObject: fetchedObject.object)
                            return person.name.lowercased().contains(text)
                        }).results.map { Person.create(from: $0.identifier, databaseObject: $0.object) }
                        
                        DispatchQueue.main.async {
                            // Only use result if we're still on the same search request
                            if thisSearchContextId == self.searchContextId {
                                self.sourceDataType = .filteredResults(searchText: text, people: results)
                                self.tableView.reloadData()
                            }
                            self.isSearching = false
                        }
                    }
                }
            })
        }
    }

}

extension ViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        guard let document = document else { return 0 }
        let people: [Person]
        switch sourceDataType {
        case .all:
            people = document.people
            
        case .filteredResults(_, let filteredResults):
            people = filteredResults
        }

        return people.count
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let document = document else { return nil }
        
        // TODO: Refactor this and put in a common people getter
        let people: [Person]
        switch sourceDataType {
        case .all:
            people = document.people
            
        case .filteredResults(_, let filteredResults):
            people = filteredResults
        }

        let person = people[row]
        if tableColumn!.identifier.rawValue == Person.namePropertyKey {
            return person.name
        } else if tableColumn!.identifier.rawValue == Person.weightPropertyKey {
            return person.weight
        } else if tableColumn!.identifier.rawValue == Person.agePropertyKey {
            return person.age
        } else {
            return nil
        }
    }
    
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let document = document else { return }
        let people: [Person]
        switch sourceDataType {
        case .all:
            people = document.people
            
        case .filteredResults(_, let filteredResults):
            people = filteredResults
        }
        
        var person = people[row]
        if let value = object as? String {
            if tableColumn!.identifier.rawValue == Person.namePropertyKey {
                person.name = value
                
                document.modifyPerson(identifier: person.identifier, properties: [Person.namePropertyKey : .string(value)])
            } else if tableColumn!.identifier.rawValue == Person.weightPropertyKey {
                if let weight = Int(value) {
                    person.weight = weight
                    document.modifyPerson(identifier: person.identifier, properties: [Person.weightPropertyKey : .int(weight)])
                }
            } else if tableColumn!.identifier.rawValue == Person.agePropertyKey {
                if let age = Int(value) {
                    person.age = age
                    document.modifyPerson(identifier: person.identifier, properties: [Person.agePropertyKey : .int(age)])
                }
            }
        }
    }
}

extension ViewController: NSTableViewDelegate {
}

extension ViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        if let textField = notification.object as? NSTextField,
            textField == searchField {
            let searchText = searchField.stringValue.lowercased()
            print("##\(searchText)##")

            self.search(text: searchText)
        }
    }
}
