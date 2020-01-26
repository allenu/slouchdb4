//
//  JSONValue.swift
//  SlouchDB3
//
//  Created by Allen Ussher on 1/4/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

// Taken from https://medium.com/grand-parade/parsing-fields-in-codable-structs-that-can-be-of-any-json-type-e0283d5edb
public enum JSONValue: Codable, Equatable {
   
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    //    case object([String: JSONValue])
    //    case array([JSONValue])
    case null
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            /*
             } else if let value = try? container.decode([String: JSONValue].self) {
             self = .object(value)
             } else if let value = try? container.decode([JSONValue].self) {
             self = .array(value)
             */
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Not a JSON"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .bool(let value):
            try container.encode(value)
            
        case .string(let value):
            try container.encode(value)
            
        case .int(let value):
            try container.encode(value)
            
        case .double(let value):
            try container.encode(value)
            
        case .null:
            try container.encodeNil()
            
        }
    }

}
