//
//  FileSystemRemoteFileStore.swift
//  SlouchDB4_Example
//
//  Created by Allen Ussher on 2/2/20.
//  Copyright © 2020 CocoaPods. All rights reserved.
//

import Foundation
import SlouchDB4

public class FileSystemRemoteFileStore: RemoteFileStoring {
    public var rootFolderUrl: URL
    public var remoteFolderUrl: URL?
    
    public init(rootFolderUrl: URL) {
        self.rootFolderUrl = rootFolderUrl
    }
    
    public func fetchRemoteFileVersions(completionHandler: @escaping (FetchRemoteFileVersionsResponse) -> Void) {
        guard let remoteFolderUrl = remoteFolderUrl else {
            DispatchQueue.main.async {
                completionHandler(.failure(reason: RemoteRequestFailureReason.noProvider))
            }
            return
        }
        
        // Enumerate folder and get file version
        var newRemoteVersion: [String : String] = [:]

        let fileEnumerator = FileManager.default.enumerator(at: remoteFolderUrl, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
        fileEnumerator?.skipDescendants()
        
        while let element = fileEnumerator?.nextObject() {
            if let fileURL = element as? URL {
                if fileURL.lastPathComponent.hasSuffix(".journal" ) {
                    let journalIdentifier = fileURL.lastPathComponent.replacingOccurrences(of: ".journal", with: "")

                    if let fileAttributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) as [FileAttributeKey : Any] {
                        if let lastModifiedDate = fileAttributes[FileAttributeKey.modificationDate] as? Date {
                            print("lastModifiedDate: \(lastModifiedDate)")
                            let dateFormatter = ISO8601DateFormatter()
                            let version = dateFormatter.string(from: lastModifiedDate)
                            
                            newRemoteVersion[journalIdentifier] = version
                        } else {
                            assertionFailure()
                        }
                    } else {
                        assertionFailure()
                    }
                }
            }
        }
        
        let response = FetchRemoteFileVersionsResponse.success(versions: newRemoteVersion)
        completionHandler(response)
    }
    
    public func push(localFile: URL, completionHandler: @escaping (PushLocalResponse) -> Void) {
        guard let remoteFolderUrl = remoteFolderUrl else {
            DispatchQueue.main.async {
                completionHandler(.failure(reason: RemoteRequestFailureReason.noProvider))
            }
            return
        }

        let destinationUrl = remoteFolderUrl.appendingPathComponent(localFile.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: localFile, to: destinationUrl)
            
            var version = "unknown"
            if let fileAttributes = try? FileManager.default.attributesOfItem(atPath: localFile.path) as [FileAttributeKey : Any] {
                if let lastModifiedDate = fileAttributes[FileAttributeKey.modificationDate] as? Date {
                    let dateFormatter = ISO8601DateFormatter()
                    version = dateFormatter.string(from: lastModifiedDate)
                }
            }
            
            completionHandler(.success(version: version))
        } catch {
            print("Error copying file \(localFile) to \(destinationUrl)")
            completionHandler(.failure(reason: .serverError))
        }
    }
    
    public func fetchFiles(identifiers: [String], completionHandler: @escaping (FetchFilesResponse) -> Void) {
        guard let remoteFolderUrl = remoteFolderUrl else {
            DispatchQueue.main.async {
                completionHandler(.failure(reason: RemoteRequestFailureReason.noProvider))
            }
            return
        }

        var filesAndVersions: [FetchedFileUrlAndVersion] = []
        identifiers.forEach { identifier in
            let remoteUrl = remoteFolderUrl.appendingPathComponent("\(identifier).journal")
            var version = "unknown"
            if let fileAttributes = try? FileManager.default.attributesOfItem(atPath: remoteUrl.path) as [FileAttributeKey : Any] {
                if let lastModifiedDate = fileAttributes[FileAttributeKey.modificationDate] as? Date {
                    let dateFormatter = ISO8601DateFormatter()
                    version = dateFormatter.string(from: lastModifiedDate)
                }
            }

            filesAndVersions.append(FetchedFileUrlAndVersion(url: remoteUrl, version: version))
        }
        
        completionHandler(.success(filesAndVersions: filesAndVersions))
    }
}

