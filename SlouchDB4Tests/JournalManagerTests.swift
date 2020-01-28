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
    func writeLocal(diffs: [ObjectDiff], to identifier: String) {
        // Who cares... doesn't need to be implemented for testing.
    }

    func localFileUrl(for identifier: String) -> URL? {
        return URL(fileURLWithPath: "/local/\(identifier)")
    }

    func readNextDiffs(from identifier: String, byteOffset: UInt64, maxDiffs: Int) -> JournalReadResult {
        // For testing, we'll consider each diff to be one byte in size
        let diffs: [ObjectDiff] = [] // TODO:
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
    func testFoo() {
        let mockRemoteFileStore = MockRemoteFileStore(fetchRemoteFileVersionsResponses: [ .success(versions: [ "aaa" : "002",
                                                                                                               "bbb" : "002",
                                                                                                               "local" : "001" ]) ],
                                                      pushLocalResponses: [.success(version: "002")],
                                                      fetchFilesResponses: [.success(filesAndVersions: [
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/aaa"), version: "002"),
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/bbb"), version: "002"),
                                                        FetchedFileUrlAndVersion(url: URL(fileURLWithPath: "/local"), version: "001"),
                                                      ])])
        let mockJournalFileManager = MockJournalFileManager()
        let storedState = JournalManagerStoredState(localIdentifier: "local",
                                                    journalByteOffsets: [:],
                                                    remoteFileVersion: [:],
                                                    lastLocalVersionPushed: "")
        
        let journalManager = JournalManager(journalFileManager: mockJournalFileManager,
                                            remoteFileStore: mockRemoteFileStore,
                                            storedState: storedState)
    }
    
    // Test fetchLatestDiffsWithoutSync
    
}
