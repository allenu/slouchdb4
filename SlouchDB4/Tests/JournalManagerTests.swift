//
//  JournalManagerTests.swift
//  SlouchDB4Tests
//
//  Created by Allen Ussher on 1/25/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import XCTest
@testable import SlouchDB4

class ItemProvider<T> {
    let items: Array<T>
    var nextItemIndex: Int
    
    init(items: Array<T>) {
        assert(items.count > 0)
        self.items = items
        nextItemIndex = 0
    }
    
    func nextItem() -> T {
        let item = items[nextItemIndex]
        nextItemIndex = nextItemIndex + 1
        return item
    }
}

class MockRemoteFileStore: RemoteFileStoring {
    let fetchRemoteFileVersionsResponsesProvider: ItemProvider<FetchRemoteFileVersionsResponse>
    let pushLocalResponsesProvider: ItemProvider<PushLocalResponse>
    let fetchFilesResponsesProvider: ItemProvider<FetchFilesResponse>

    init(fetchRemoteFileVersionsResponses: [FetchRemoteFileVersionsResponse],
         pushLocalResponses: [PushLocalResponse],
         fetchFilesResponses: [FetchFilesResponse]
         ) {
        fetchRemoteFileVersionsResponsesProvider = ItemProvider(items: fetchRemoteFileVersionsResponses)
        pushLocalResponsesProvider = ItemProvider(items: pushLocalResponses)
        fetchFilesResponsesProvider = ItemProvider(items: fetchFilesResponses)
    }
    
    func fetchRemoteFileVersions(completionHandler: @escaping (FetchRemoteFileVersionsResponse) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: {
            completionHandler(self.fetchRemoteFileVersionsResponsesProvider.nextItem())
        })
    }
    
    func push(localFile: URL, completionHandler: @escaping (PushLocalResponse) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: {
            completionHandler(self.pushLocalResponsesProvider.nextItem())
        })
    }
    
    func fetchFiles(identifiers: [String], completionHandler: @escaping (FetchFilesResponse) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
            completionHandler(self.fetchFilesResponsesProvider.nextItem())
        })
    }
}

class MockJournalFileManager: JournalFileManaging {
    let totalCommands: [String : Int]
    let startDate: Date
    
    init(totalCommands: [String : Int], startDate: Date) {
        self.totalCommands = totalCommands
        self.startDate = startDate
    }
    
    func writeLocal(commands: [Command], to identifier: String) {
        // Who cares... doesn't need to be implemented for testing.
    }

    func localFileUrl(for identifier: String) -> URL? {
        return URL(fileURLWithPath: "/local/\(identifier)")
    }

    func readNextCommands(from identifier: String, byteOffset: UInt64, maxCommands: Int) -> JournalReadResult {
        let totalCommandsForThisJournal = totalCommands[identifier] ?? 0
        let commandsRemaining = max(0, Int(totalCommandsForThisJournal) - Int(byteOffset))
        let commandsToReturn = min(commandsRemaining, maxCommands)
        
        // For testing, we'll consider each command to be one byte in size
        let commands: [Command] = Array(0..<commandsToReturn).map { index in
            let startCommandIndex = Int(byteOffset)
            let commandIndex = startCommandIndex + index
            let identifier = "\(identifier)-\(commandIndex)"
            let timestamp = startDate.addingTimeInterval(TimeInterval(commandIndex))
            let object = DatabaseObject(type: "person", properties: ["name" : .string("Name-\(commandIndex)")])
            let command = Command.insert(identifier: identifier, timestamp: timestamp, object: object)
            return command
        }
        let newByteOffset = byteOffset + UInt64(commands.count)
        
        return JournalReadResult(commands: commands, byteOffset: newByteOffset)
    }
    
    func replaceRemoteJournalFile(identifier: String, with url: URL, completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: {
            completion()
        })
    }
}

class JournalManagerTests: XCTestCase {

    // Test fetchLatestCommandsWithoutSync
    func testNoChanges() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [])])
        let totalCommands: [String : Int] = [
            "j1" : 0,
            "j2" : 0
        ]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalCommands: totalCommands, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["j1" : 0, "j2" : 0],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        
        journalManager.fetchLatestCommandsWithoutSync(completion: { response, callback in
            switch response {
            case .success(let type):
                switch type {
                case .partialResults:
                    XCTFail()

                case .results(let commands):
                    XCTAssert(commands.count == 0)
                    
                    callback?(true)
                }
                
            case .failure:
                XCTFail()
            }
        })
    }
    
    // Test that if we have 115 changes where 100 is max fetch each time, then if we do
    // two requests we should get 100 commands back and then 15 commands back.
    func testMoreThanMaxChanges() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [])])
        let totalCommands: [String : Int] = [
            "j1" : 105,
            "j2" : 10
        ]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalCommands: totalCommands, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["j1" : 0, "j2" : 0],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        
        // Store all commands here after fetching. We want to inspect them all, but we're
        // not really guaranteed the order in which we'll read them across multiple
        // journals, so we'll need to sort them to verify the contents.
        var allCommands: [Command] = []
        
        let waitForSecondRequest = expectation(description: "wait for second request to finish")

        let secondRequest: () -> Void = {
            journalManager.fetchLatestCommandsWithoutSync(completion: { response, callback in
                switch response {
                case .success(let type):
                    switch type {
                        case .partialResults:
                        XCTFail()
                            
                    case .results(let commands):
                        XCTAssert(commands.count == 15)

                        allCommands.append(contentsOf: commands)
                        
                        let sortedCommands = allCommands.sorted(by: { $0.timestamp < $1.timestamp })
                        
                        // Verify first 100 are from j1 and second 10 are from j2
                        sortedCommands
                            .filter { $0.identifier.starts(with: "j1") }
                            .enumerated()
                            .forEach( { index, command in
                            XCTAssert(command.identifier == "j1-\(index)")
                        })

                        sortedCommands
                            .filter { $0.identifier.starts(with: "j2") }
                            .enumerated()
                            .forEach( { index, command in
                            XCTAssert(command.identifier == "j2-\(index)")
                        })
                        
                        waitForSecondRequest.fulfill()

                    }

                case .failure:
                    XCTFail()
                }
            })
        }
        
        journalManager.fetchLatestCommandsWithoutSync(completion: { response, callback in
            switch response {
            case .success(let type):
                switch type {
                case .partialResults(let commands, _):
                    XCTAssert(commands.count == journalManager.maxCommands)
                    
                    allCommands.append(contentsOf: commands)
                    
                    // MUST call this back so that journalManager can update its offsets
                    callback?(true)
                    
                    secondRequest()

                case .results:
                    XCTFail()
                }
                
            case .failure:
                XCTFail()
            }
        })
        
        waitForExpectations(timeout: 1.0, handler: nil)
    }
    
    func testAbitFromEach() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [ "j1" : "002",
                                                                                                               "j2" : "002",
                                                                                                               "local" : "001" ]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/aaa"), version: "002"),
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/bbb"), version: "002"),
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/local"), version: "001"),
                                                      ])])
        let totalCommands: [String : Int] = [
            "j1" : 5,
            "j2" : 10
        ]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalCommands: totalCommands, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["j1" : 0, "j2" : 0],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)

        let waitForBlock = expectation(description: "wait for completion block")

        journalManager.fetchLatestCommandsWithoutSync(completion: { response, callback in
            switch response {
            case .success(let type):
                switch type {
                case .partialResults:
                    XCTFail()

                case .results(let commands):
                    XCTAssert(commands.count == 15)
                    
                    // Verify that journal byte offsets are unchanged until we call callback
                    XCTAssert(journalManager.journalByteOffsets["j1"] == 0)
                    XCTAssert(journalManager.journalByteOffsets["j2"] == 0)
                    
                    // TODO: Verify each command to make sure we got back 5 from j1 and 10 from j2
                    callback?(true)

                    // After callback, they are updated
                    XCTAssert(journalManager.journalByteOffsets["j1"] == 5)
                    XCTAssert(journalManager.journalByteOffsets["j2"] == 10)
                    
                    waitForBlock.fulfill()
                }
                
            case .failure:
                XCTFail()
            }
        })
        waitForExpectations(timeout: 1.0, handler: nil)
    }
    
    // Test syncing
    
    func testSyncNoLocalsNoRemotes() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                      ])])
        let totalCommands: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalCommands: totalCommands, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: [:],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        
        let waitForBlock = expectation(description: "wait for completion block")

        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 0)
                XCTAssert(journalManager.journalByteOffsets.count == 0)
                
                waitForBlock.fulfill()
                
            case .failure:
                XCTFail()
            }
        })
        waitForExpectations(timeout: 1.0, handler: nil)
    }

    func testSyncFetchOneRemoteThatWeDontHaveYet() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: ["abc": "2"]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/abc"), version: "2"),
                                                      ])])
        let totalCommands: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalCommands: totalCommands, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: [:],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        
        let waitForBlock = expectation(description: "wait for completion block")

        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 1)
                XCTAssert(updatedFiles.first! == "abc")
                XCTAssert(journalManager.journalByteOffsets.count == 1) // Create a new entry for it after fetching, set at byte offset 0
                XCTAssert(journalManager.journalByteOffsets["abc"] == 0)
                
                waitForBlock.fulfill()
                
            case .failure:
                XCTFail()
            }
        })
        waitForExpectations(timeout: 1.0, handler: nil)
    }

    func testSyncDoNotFetchOneRemoteIfVersionIsSame() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/abc"), version: "2"),
                                                      ])])
        let totalCommands: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalCommands: totalCommands, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["abc":0],
                                                    remoteFileVersion: ["abc": "2"], // *** same as remote version ***
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        
        let waitForBlock = expectation(description: "wait for completion block")

        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 0) // No changes
                XCTAssert(journalManager.journalByteOffsets.count == 1)
                XCTAssert(journalManager.journalByteOffsets["abc"] == 0)
                
                waitForBlock.fulfill()
                
            case .failure:
                XCTFail()
            }
        })
        waitForExpectations(timeout: 1.0, handler: nil)
    }
    
    func testSyncFetchOneUpdatedRemoteThatWeAlreadyHave() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: ["abc":"2"]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/abc"), version: "2"),
                                                      ])])
        let totalCommands: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalCommands: totalCommands, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["abc":0],
                                                    remoteFileVersion: ["abc": "1"],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        
        let waitForBlock = expectation(description: "wait for completion block")

        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 1) // Update "abc" since remote version is newer
                XCTAssert(updatedFiles.first! == "abc")
                XCTAssert(journalManager.journalByteOffsets.count == 1) // Create a new entry for it after fetching, set at byte offset 0
                XCTAssert(journalManager.journalByteOffsets["abc"] == 0)
                
                waitForBlock.fulfill()
                
            case .failure:
                XCTFail()
            }
        })
        waitForExpectations(timeout: 1.0, handler: nil)
    }
    
    func testSyncTwoRemotesWeDoNotHaveYet() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: ["abc":"2", "def": "2"]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/abc"), version: "2"),
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/def"), version: "2"),
                                                      ])])
        let totalCommands: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalCommands: totalCommands, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: [:],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        
        let waitForBlock = expectation(description: "wait for completion block")

        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 2) // Update "abc" and "def"
                XCTAssert(updatedFiles.contains("abc"))
                XCTAssert(updatedFiles.contains("def"))
                
                waitForBlock.fulfill()
                
            case .failure:
                XCTFail()
            }
        })
        waitForExpectations(timeout: 1.0, handler: nil)
    }

    
    func testSyncTwoRemotesButOnlyOneIsNewer() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: ["abc":"2", "def":"2"]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/abc"), version: "2"),
                                                      ])])
        let totalCommands: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalCommands: totalCommands, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["abc":0, "def":0],
                                                    remoteFileVersion: ["abc": "1", "def":"2"], // Already know about version "2" of def
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        
        let waitForBlock = expectation(description: "wait for completion block")

        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 1) // Update "abc" only
                XCTAssert(updatedFiles.first! == "abc")
                
                waitForBlock.fulfill()
                
            case .failure:
                XCTFail()
            }
        })
        
        waitForExpectations(timeout: 100.0, handler: nil)
    }
}
