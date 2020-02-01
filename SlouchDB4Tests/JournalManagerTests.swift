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

class MockRemoteFileStore: RemoteFileStore {
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
    let totalDiffs: [String : Int]
    let startDate: Date
    
    init(totalDiffs: [String : Int], startDate: Date) {
        self.totalDiffs = totalDiffs
        self.startDate = startDate
    }
    
    func writeLocal(diffs: [ObjectDiff], to identifier: String) {
        // Who cares... doesn't need to be implemented for testing.
    }

    func localFileUrl(for identifier: String) -> URL? {
        return URL(fileURLWithPath: "/local/\(identifier)")
    }

    func readNextDiffs(from identifier: String, byteOffset: UInt64, maxDiffs: Int) -> JournalReadResult {
        let totalDiffsForThisJournal = totalDiffs[identifier] ?? 0
        let diffsRemaining = max(0, Int(totalDiffsForThisJournal) - Int(byteOffset))
        let diffsToReturn = min(diffsRemaining, maxDiffs)
        
        // For testing, we'll consider each diff to be one byte in size
        let diffs: [ObjectDiff] = Array(0..<diffsToReturn).map { index in
            let identifier = "\(identifier)-\(index)"
            let timestamp = startDate.addingTimeInterval(TimeInterval(index))
            let object = DatabaseObject(type: "person", properties: ["name" : .string("Name-\(index)")])
            let diff = ObjectDiff.insert(identifier: identifier, timestamp: timestamp, object: object)
            return diff
        }
        let newByteOffset = byteOffset + UInt64(diffs.count)
        
        return JournalReadResult(diffs: diffs, byteOffset: newByteOffset)
    }
    
    func replaceRemoteJournalFile(identifier: String, with url: URL, completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: {
            completion()
        })
    }
}

class JournalManagerTests: XCTestCase {
    
    // Just to retain journalManager in tests
    var journalManager: JournalManager?

    // Test fetchLatestDiffsWithoutSync
    func testNoChanges() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [])])
        let totalDiffs: [String : Int] = [
            "j1" : 0,
            "j2" : 0
        ]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalDiffs: totalDiffs, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["j1" : 0, "j2" : 0],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        self.journalManager = journalManager
        
        journalManager.fetchLatestDiffsWithoutSync(completion: { response, callback in
            switch response {
            case .success(let type):
                switch type {
                case .partialResults:
                    XCTFail()

                case .results(let diffs):
                    XCTAssert(diffs.count == 0)
                    
                    callback?(true)
                }
                
            case .failure:
                XCTFail()
            }
        })
    }
    
    // Test that if we have 115 changes where 100 is max fetch each time, then if we do
    // two requests we should get 100 diffs back and then 15 diffs back.
    func testMoreThanMaxChanges() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [])])
        let totalDiffs: [String : Int] = [
            "j1" : 105,
            "j2" : 10
        ]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalDiffs: totalDiffs, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["j1" : 0, "j2" : 0],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        self.journalManager = journalManager
        
        // Store all diffs here after fetching. We want to inspect them all, but we're
        // not really guaranteed the order in which we'll read them across multiple
        // journals, so we'll need to sort them to verify the contents.
        var allDiffs: [ObjectDiff] = []
        
        let secondRequest: () -> Void = {
            journalManager.fetchLatestDiffsWithoutSync(completion: { response, callback in
                switch response {
                case .success(let type):
                    switch type {
                        case .partialResults:
                        XCTFail()
                            
                    case .results(let diffs):
                        XCTAssert(diffs.count == 15)

                        allDiffs.append(contentsOf: diffs)
                        
                        let sortedDiffs = diffs.sorted(by: { $0.identifier < $1.identifier })
                        
                        // Verify first 105 are from j1 and second 10 are from j2
                        sortedDiffs.prefix(105).enumerated().forEach( { index, diff in
                            XCTAssert(diff.identifier == "j1-\(index + 100)")
                        })

                        diffs.suffix(10).enumerated().forEach( { index, diff in
                            XCTAssert(diff.identifier == "j2-\(index)")
                        })

                    }

                case .failure:
                    XCTFail()
                }
            })
        }
        
        journalManager.fetchLatestDiffsWithoutSync(completion: { response, callback in
            switch response {
            case .success(let type):
                switch type {
                case .partialResults(let diffs, _):
                    XCTAssert(diffs.count == journalManager.maxDiffs)
                    
                    allDiffs.append(contentsOf: diffs)
                    
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
        let totalDiffs: [String : Int] = [
            "j1" : 5,
            "j2" : 10
        ]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalDiffs: totalDiffs, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["j1" : 0, "j2" : 0],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        self.journalManager = journalManager
        
        journalManager.fetchLatestDiffsWithoutSync(completion: { response, callback in
            switch response {
            case .success(let type):
                switch type {
                case .partialResults:
                    XCTFail()

                case .results(let diffs):
                    XCTAssert(diffs.count == 15)
                    
                    // Verify that journal byte offsets are unchanged until we call callback
                    XCTAssert(journalManager.journalByteOffsets["j1"] == 0)
                    XCTAssert(journalManager.journalByteOffsets["j2"] == 0)
                    
                    // TODO: Verify each diff to make sure we got back 5 from j1 and 10 from j2
                    callback?(true)

                    // After callback, they are updated
                    XCTAssert(journalManager.journalByteOffsets["j1"] == 5)
                    XCTAssert(journalManager.journalByteOffsets["j2"] == 10)
                }
                
            case .failure:
                XCTFail()
            }
        })
    }
    
    // Test syncing
    
    func testSyncNoLocalsNoRemotes() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                      ])])
        let totalDiffs: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalDiffs: totalDiffs, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: [:],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        self.journalManager = journalManager
        
        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 0)
                XCTAssert(journalManager.journalByteOffsets.count == 0)
                
            case .failure:
                XCTFail()
            }
        })
    }

    func testSyncFetchOneRemoteThatWeDontHaveYet() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/abc"), version: "2"),
                                                      ])])
        let totalDiffs: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalDiffs: totalDiffs, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: [:],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        self.journalManager = journalManager
        
        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 1)
                XCTAssert(updatedFiles.first! == "abc")
                XCTAssert(journalManager.journalByteOffsets.count == 1) // Create a new entry for it after fetching, set at byte offset 0
                XCTAssert(journalManager.journalByteOffsets["abc"] == 0)
                
            case .failure:
                XCTFail()
            }
        })
    }

    func testSyncDoNotFetchOneRemoteIfVersionIsSame() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/abc"), version: "2"),
                                                      ])])
        let totalDiffs: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalDiffs: totalDiffs, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["abc":0],
                                                    remoteFileVersion: ["abc": "2"], // *** same as remote version ***
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        self.journalManager = journalManager
        
        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 0) // No changes
                XCTAssert(journalManager.journalByteOffsets.count == 1)
                XCTAssert(journalManager.journalByteOffsets["abc"] == 0)
                
            case .failure:
                XCTFail()
            }
        })
    }
    
    func testSyncFetchOneUpdatedRemoteThatWeAlreadyHave() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/abc"), version: "2"),
                                                      ])])
        let totalDiffs: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalDiffs: totalDiffs, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["abc":0],
                                                    remoteFileVersion: ["abc": "1"],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        self.journalManager = journalManager
        
        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 1) // Update "abc" since remote version is newer
                XCTAssert(updatedFiles.first! == "abc")
                XCTAssert(journalManager.journalByteOffsets.count == 1) // Create a new entry for it after fetching, set at byte offset 0
                XCTAssert(journalManager.journalByteOffsets["abc"] == 0)
                
            case .failure:
                XCTFail()
            }
        })
    }
    
    func testSyncTwoRemotesWeDoNotHaveYet() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/abc"), version: "2"),
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/def"), version: "2"),
                                                      ])])
        let totalDiffs: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalDiffs: totalDiffs, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: [:],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        self.journalManager = journalManager
        
        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 2) // Update "abc" and "def"
                XCTAssert(updatedFiles.contains("abc"))
                XCTAssert(updatedFiles.contains("def"))
                
            case .failure:
                XCTFail()
            }
        })
    }

    
    func testSyncTwoRemotesButOnlyOneIsNewer() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [:]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/abc"), version: "2"),
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/def"), version: "2"),
                                                      ])])
        let totalDiffs: [String : Int] = [:]
        let now = Date()
        let mockJournalFileManager = MockJournalFileManager(totalDiffs: totalDiffs, startDate: now)
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: ["abc":0, "def":0],
                                                    remoteFileVersion: ["abc": "1", "def":"2"], // Already know about version "2" of def
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
        self.journalManager = journalManager
        
        journalManager.syncFiles(completion: { response in
            switch response {
            case .success(let updatedFiles):
                XCTAssert(updatedFiles.count == 1) // Update "abc" only
                XCTAssert(updatedFiles.first! == "abc")
                
            case .failure:
                XCTFail()
            }
        })
    }
}
