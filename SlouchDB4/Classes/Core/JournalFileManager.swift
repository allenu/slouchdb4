//
//  JournalFileManager.swift
//  Pods
//
//  Created by Allen Ussher on 2/1/20.
//

import Foundation

public class JournalFileManager: JournalFileManaging {
    public var folderUrl: URL?
    
    public init(folderUrl: URL? = nil) {
        self.folderUrl = folderUrl
    }
    
    public func writeLocal(diffs: [ObjectDiff], to identifier: String) {
        // TODO:
    }
    
    public func localFileUrl(for identifier: String) -> URL? {
        // TODO:
        return nil
    }
    
    public func replaceRemoteJournalFile(identifier: String, with url: URL, completion: @escaping () -> Void) {
        // TODO:
    }
    
    public func readNextDiffs(from identifier: String, byteOffset: UInt64, maxDiffs: Int) -> JournalReadResult {
        // TODO:
        return JournalReadResult(diffs: [], byteOffset: 0)
    }
    
    
}
