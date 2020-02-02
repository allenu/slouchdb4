//
//  Person.swift
//  PeopleApp2
//
//  Created by Allen Ussher on 1/18/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

struct Person {
    let identifier: String
    var name: String
    var weight: Int
    var age: Int
    
    static let namePropertyKey = "name"
    static let weightPropertyKey = "weight"
    static let agePropertyKey = "age"
}
