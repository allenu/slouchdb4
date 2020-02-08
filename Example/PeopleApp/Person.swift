//
//  Person.swift
//  PeopleApp2
//
//  Created by Allen Ussher on 1/18/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation
import SlouchDB4

struct Person {
    let identifier: String
    var name: String
    var weight: Int
    var age: Int
    
    static let namePropertyKey = "name"
    static let weightPropertyKey = "weight"
    static let agePropertyKey = "age"
    
    static func create(from identifier: String, databaseObject: DatabaseObject) -> Person {
        let name: String
        let age: Int
        let weight: Int

        if let nameProperty = databaseObject.properties[Person.namePropertyKey],
            case let JSONValue.string(value) = nameProperty {
            name = value
        } else {
            name = "Unnamed"
        }

        if let ageProperty = databaseObject.properties[Person.agePropertyKey],
            case let JSONValue.int(value) = ageProperty {
            age = value
        } else {
            age = 0
        }

        if let weightProperty = databaseObject.properties[Person.weightPropertyKey],
            case let JSONValue.int(value) = weightProperty {
            weight = value
        } else {
            weight = 0
        }

        return Person(identifier: identifier,
                      name: name,
                      weight: weight,
                      age: age)
    }
}
