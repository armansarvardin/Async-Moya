//
//  AsyncPluginType.swift
//  Moya
//
//  Created by Arman Sarvardin on 28.01.2025.
//


//
//  AsyncPluginType.swift
//  Moya
//
//  Created by Arman Sarvardin on 28.01.2025.
//


import Foundation

/// A Moya Plugin receives callbacks to perform side effects wherever a request is sent or received.
///
/// for example, a plugin may be used to
///     - log network requests
///     - hide and show a network activity indicator
///     - inject additional information into a request
///
public protocol AsyncPluginType: PluginType {
    /// Called to modify a request before sending.
    func prepare(
        _ request: URLRequest,
        target: TargetType
    ) async throws -> URLRequest

    /// Called immediately before a request is sent over the network (or stubbed).
    func willSend(
        _ request: URLRequest,
        target: TargetType
    )

    /// Called after a response has been received, but before the MoyaProvider has invoked its completion handler.
    func didReceive(
        _ result: Result<Moya.Response, MoyaError>,
        target: TargetType
    )

    /// Called to modify a result before completion.
    func process(
        _ response: Response,
        target: TargetType
    ) async throws -> Response
}

public extension AsyncPluginType {
    
    func prepare(
        _ request: URLRequest,
        target: TargetType
    ) async throws -> URLRequest {
        request
    }
    
    func willSend(
        _ request: URLRequest,
        target: TargetType
    ) { }
    
    func didReceive(
        _ result: Result<Moya.Response,MoyaError>,
        target: TargetType
    ) { }
    
    func process(
        _ response: Response,
        target: TargetType
    ) async throws -> Response {
        response
    }
}
