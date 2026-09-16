//
//  Collections.swift  (Weather)
//
//  The one general-purpose helper the weather views borrowed from elsewhere in
//  Almanac. It lived on an unrelated file there (`LinkPalette.swift`), which is
//  a fair illustration of why the app was worth splitting.
//

import Foundation

extension Array {
    /// Indexing that admits the index might not be there, instead of trapping.
    /// Used where a frame is addressed by a position that a shorter loop may not
    /// have — a radar sequence that has not finished filling is the normal case,
    /// not an error.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
