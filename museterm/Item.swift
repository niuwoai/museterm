//
//  Item.swift
//  museterm
//
//  Created by rocky on 2026/6/30.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
