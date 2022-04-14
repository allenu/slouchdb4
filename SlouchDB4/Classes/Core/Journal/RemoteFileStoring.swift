//
//  RemoteFileStore.swift
//  SlouchDB4
//
//  Created by Allen Ussher on 1/25/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

public enum RemoteRequestFailureReason {
    case noNetwork
    case noProvider
    case networkError
    case unauthorized
    case serverError
    case timeout
}

public enum PushLocalResponse {
    case success(version: String)
    case failure(reason: RemoteRequestFailureReason)
}

public enum FetchRemoteFileVersionsResponse {
    case success(versions: [String : String])
    case failure(reason: RemoteRequestFailureReason)
}

public struct FetchedFileUrlAndVersion {
    public let url: URL
    public let version: String
    public init(url: URL, version: String) {
        self.url = url
        self.version = version
    }
}

public enum FetchFilesResponse {
    case success(filesAndVersions: [FetchedFileUrlAndVersion])
    case failure(reason: RemoteRequestFailureReason)
}

public protocol RemoteFileStoring: AnyObject {
    func fetchRemoteFileVersions(completionHandler: @escaping (FetchRemoteFileVersionsResponse) -> Void)

    func push(localFile: URL, completionHandler: @escaping (PushLocalResponse) -> Void)
    
    func fetchFiles(identifiers: [String], completionHandler: @escaping (FetchFilesResponse) -> Void)
}
