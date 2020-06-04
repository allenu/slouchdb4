//
//  Person.swift
//  PeopleApp2
//
//  Created by Allen Ussher on 1/18/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation
import SlouchDB4

struct Person: Codable {
    let identifier: String
    var name: String
    var weight: Int
    var age: Int
}
