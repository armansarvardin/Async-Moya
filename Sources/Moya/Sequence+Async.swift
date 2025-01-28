//
//  Sequence+Async.swift
//  Moya
//
//  Created by Arman Sarvardin on 28.01.2025.
//


//
//  File.swift
//  Moya
//
//  Created by Arman Sarvardin on 28.01.2025.
//


//
//  Sequence+Async.swift
//  Moya
//
//  Created by Arman Sarvardin on 27.01.2025.
//

import Foundation

extension Sequence {
    func asyncReduce<U>(
        _ initialResult: U,
        _ nextPartialResult: @escaping (U, Element) async throws -> U
    ) async rethrows -> U {
        var accumulator = initialResult
        for element in self {
            accumulator = try await nextPartialResult(accumulator, element)
        }
        return accumulator
    }
}
