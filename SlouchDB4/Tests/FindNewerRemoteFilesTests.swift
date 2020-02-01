//
//  FindNewerRemoteFilesTests.swift
//  SlouchDB4Tests
//
//  Created by Allen Ussher on 1/27/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import XCTest
@testable import SlouchDB4

class FindNewerRemoteFilesTests: XCTestCase {
    
    func testNoLocalFilesNoRemotes() {
        let localIdentifier = "local"
        let localFileVersions: [String : String] = [:]
        let remoteFileVersions: [String : String] = [:]
        let filesToFetch = findNewerRemoteFiles(excludedFiles: [localIdentifier],
                                                localFileVersions: localFileVersions,
                                                remoteFileVersions: remoteFileVersions)
        
        XCTAssert(filesToFetch.count == 0)
    }

    func testTwoLocalFilesNoRemotes() {
        let localIdentifier = "local"
        let localFileVersions: [String : String] = [ "file1" : "1", "file2" : "2" ]
        let remoteFileVersions: [String : String] = [:]
        let filesToFetch = findNewerRemoteFiles(excludedFiles: [localIdentifier],
                                                localFileVersions: localFileVersions,
                                                remoteFileVersions: remoteFileVersions)
        
        // Nothing to pull down
        XCTAssert(filesToFetch.count == 0)
    }

    func testNoLocalFiles() {
        let localIdentifier = "local"
        let localFileVersions: [String : String] = [:]
        let remoteFileVersions: [String : String] = [ "file1" : "1", "file2" : "2" ]
        let filesToFetch = findNewerRemoteFiles(excludedFiles: [localIdentifier],
                                                localFileVersions: localFileVersions,
                                                remoteFileVersions: remoteFileVersions)
        
        XCTAssert(filesToFetch.count == 2)
        XCTAssert(filesToFetch.contains("file1"))
        XCTAssert(filesToFetch.contains("file2"))
    }

    func testOneLocalFileSameAsRemote() {
        let localIdentifier = "local"
        let localFileVersions: [String : String] = ["file1" : "1"]
        let remoteFileVersions: [String : String] = [ "file1" : "1", "file2" : "2" ]
        let filesToFetch = findNewerRemoteFiles(excludedFiles: [localIdentifier],
                                                localFileVersions: localFileVersions,
                                                remoteFileVersions: remoteFileVersions)
        
        XCTAssert(filesToFetch.count == 1)
        XCTAssert(filesToFetch.contains("file2"))
    }

    func testTwoLocalsFilesSameAsRemote() {
        let localIdentifier = "local"
        let localFileVersions: [String : String] = ["file1" : "1", "file2" : "2"]
        let remoteFileVersions: [String : String] = [ "file1" : "1", "file2" : "2" ]
        let filesToFetch = findNewerRemoteFiles(excludedFiles: [localIdentifier],
                                                localFileVersions: localFileVersions,
                                                remoteFileVersions: remoteFileVersions)
        
        XCTAssert(filesToFetch.count == 0)
    }

    func testOneLocalFileOlderThanRemoteOtherDoesntExist() {
        let localIdentifier = "local"
        let localFileVersions: [String : String] = ["file1" : "1"]
        let remoteFileVersions: [String : String] = [ "file1" : "2", "file2" : "2" ]
        let filesToFetch = findNewerRemoteFiles(excludedFiles: [localIdentifier],
                                                localFileVersions: localFileVersions,
                                                remoteFileVersions: remoteFileVersions)
        
        XCTAssert(filesToFetch.count == 2)
        XCTAssert(filesToFetch.contains("file1"))
        XCTAssert(filesToFetch.contains("file2"))
    }

    func testTwoLocalFilesOlderThanRemotes() {
        let localIdentifier = "local"
        let localFileVersions: [String : String] = ["file1" : "1", "file2" : "2"]
        let remoteFileVersions: [String : String] = [ "file1" : "2", "file2" : "3" ]
        let filesToFetch = findNewerRemoteFiles(excludedFiles: [localIdentifier],
                                                localFileVersions: localFileVersions,
                                                remoteFileVersions: remoteFileVersions)
        
        XCTAssert(filesToFetch.count == 2)
        XCTAssert(filesToFetch.contains("file1"))
        XCTAssert(filesToFetch.contains("file2"))
    }

    func testExcludeLocalFiles() {
        let localFileVersions: [String : String] = [:]
        let remoteFileVersions: [String : String] = [ "local1" : "1", "local2" : "2" ]
        let filesToFetch = findNewerRemoteFiles(excludedFiles: ["local1", "local2"],
                                                localFileVersions: localFileVersions,
                                                remoteFileVersions: remoteFileVersions)
        
        XCTAssert(filesToFetch.count == 0)
    }

}
