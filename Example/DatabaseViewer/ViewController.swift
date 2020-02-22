//
//  ViewController.swift
//  DatabaseViewer
//
//  Created by Allen Ussher on 2/15/20.
//  Copyright © 2020 CocoaPods. All rights reserved.
//

import Cocoa
import SlouchDB4

class ViewController: NSViewController {
    var session: Session?
    var remoteFolder: URL?
    let itemsPerPage: Int = 10
    
    // Our best guess of number of items in the database
    var numberOfItems: Int = 0
    var fetchedObjects: [FetchedDatabaseObject] = []
    var shouldFetchMoreItems: Bool = false
    var fetchCursor: FetchCursor?
    var isFetching = false
    
    @IBOutlet weak var pathTextField: NSTextField!
    @IBOutlet weak var tableView: NSTableView!
    
    func loadDatabase(from url: URL) {
        
        let directory = NSTemporaryDirectory()
        let subpath = UUID().uuidString
        let tempUrl = NSURL.fileURL(withPathComponents: [directory, subpath])!

        // Nothing loaded yet. We'll just do a sync to pull it all in.
        let objectStore = InMemObjectStore()
        let objectHistoryStore = InMemObjectHistoryStore()
        let objectHistoryTracker = ObjectHistoryTracker(objectHistoryStore: objectHistoryStore)
        let database = Database(objectStore: objectStore, objectHistoryTracker: objectHistoryTracker, sortedIdentifiers: [])
        
        let journalFileManager = JournalFileManager(workingFolderUrl: tempUrl)
        let remoteFileStore = FileSystemRemoteFileStore()
        remoteFileStore.remoteFolderUrl = url
        
        let storedState = JournalManagerStoredState(localIdentifier: "local-unused", journalByteOffsets: [:], remoteFileVersion: [:], lastLocalVersionPushed: "none")
        let journalManager = JournalManager(journalFileManager: journalFileManager, remoteFileStore: remoteFileStore, storedState: storedState)
        
        let session = Session(database: database, journalManager: journalManager)
        
        // Sync it ...
        session.sync(completion: { response in
            switch response {
            case .failure:
                print("Couldn't load that URL")
                
            case .success:
                DispatchQueue.main.async {
                    self.session = session
                    self.numberOfItems = 0
                    self.fetchedObjects = []
                    self.fetchCursor = nil
                    
                    self.tableView.reloadData()
                    
                    self.isFetching = true
                    
                    // Go ahead and fetch more items
                    DispatchQueue.global().async {
                        let result = session.fetch(of: "card", limitCount: self.itemsPerPage * 2)
                        
                        DispatchQueue.main.async {
                            self.numberOfItems = result.results.count
                            self.fetchedObjects = result.results
                            self.fetchCursor = result.cursor
                            self.isFetching = false
                            self.tableView.reloadData()
                        }
                    }
                }
            }
        }, partialResults: { percent in
            
        })
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        tableView.dataSource = self
        
        // Need to listen to when user scrolls too far
        self.tableView.enclosingScrollView?.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didObserveScroll(notification:)), name: NSView.boundsDidChangeNotification, object: self.tableView.enclosingScrollView?.contentView)
    }
    
    @objc func didObserveScroll(notification: NSNotification) {
        print("Scroll position: \(tableView.enclosingScrollView?.contentView.bounds.origin.y)")
        
        // Figure out content size of the window area by getting tableView height
        let tableViewHeight = tableView.bounds.height
        // Figure out the index of the last row showing by taking origin position of the scroll view and adding table height
        let firstRowY = (tableView.enclosingScrollView?.contentView.bounds.origin.y ?? 0)
        let maxY = firstRowY + tableViewHeight
        let point = CGPoint(x: 0, y: maxY)
        let index = tableView.row(at: point)
        print("last row index there is \(index)")
        
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        let firstVisibleRow = visibleRows.location
        let lastVisibleRow = visibleRows.location + visibleRows.length
        print("lastVisibleRow is \(lastVisibleRow)")
        
        guard let session = session else { return }
        
        // Assume we have to add one (hack)
        let row = index + 1
        
        // If the row we are loading is beyond a certain point in the list, then we should go fetch more data
        let fetchTrigger: Int = fetchedObjects.count - itemsPerPage / 2
        if lastVisibleRow >= fetchTrigger && !isFetching {
            if let cursor = self.fetchCursor {
                if !cursor.noMoreResults {
                    // More to fetch, so let's do it
                    isFetching = true
                    DispatchQueue.global().async {
                        let result = session.fetchMore(cursor: cursor, limitCount: self.itemsPerPage)

                        DispatchQueue.main.async {
                            let oldCount = self.fetchedObjects.count
                            
                            self.fetchedObjects.append(contentsOf: result.results)
                            self.fetchCursor = result.cursor
                            self.isFetching = false

                            print("had \(oldCount) items and now have \(self.fetchedObjects.count)")

                            var indexSet = IndexSet()
                            Array(oldCount..<self.fetchedObjects.count).forEach { index in
                                print("inserting item at index \(index)")
                                indexSet.insert(index)
                            }
                            self.tableView.beginUpdates()
                            self.tableView.insertRows(at: indexSet, withAnimation: .slideDown)
                            self.tableView.endUpdates()
                        }
                    }
                } else {
                    print("No more results to show")
                }
            } else {
                assertionFailure("Should always have a cursor at this point")
            }
        }
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    @IBAction func didTapSyncLocation(sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.begin(completionHandler: { result in
            if result == NSApplication.ModalResponse.OK {
                
                if let remoteUrl = openPanel.urls.first {
                    self.remoteFolder = remoteUrl
                    
                    DispatchQueue.main.async {
                        self.pathTextField.stringValue = remoteUrl.path
                        
                        DispatchQueue.global().async {
                            self.loadDatabase(from: remoteUrl)
                        }
                    }
                }
            }
        })
    }
}

extension ViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return fetchedObjects.count
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let session = session else { return nil }
        guard row < self.fetchedObjects.count else {
            return nil
        }
        
        let object = self.fetchedObjects[row]
        
        if tableColumn!.identifier.rawValue == "identifier" {
            return object.identifier
        } else if tableColumn!.identifier.rawValue == "type" {
            return object.object.type
        } else {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try! encoder.encode(object.object)
            let str = String(data: jsonData, encoding: .utf8)!
            return str
        }
    }
}

