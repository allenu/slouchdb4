//
//  ObjectHistoryStoring.swift
//  Pods
//
//  Created by Allen Ussher on 2/20/20.
//

import Foundation

public protocol ObjectHistoryStoring {
    func insertPendingUpdate(for identifier: String)
    func removePendingUpdate(for identifier: String)
    func pendingUpdates() -> [String]
    
    func objectHistoryState(for identifier: String) -> ObjectHistoryState?
    func update(objectHistoryState: ObjectHistoryState, for identifier: String)

    func save(to fileUrl: URL)
    
    func resetSyncState()
}
