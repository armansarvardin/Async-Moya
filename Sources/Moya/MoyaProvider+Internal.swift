import Foundation
import Alamofire

// MARK: - Method

public extension Method {
    /// A Boolean value determining whether the request supports multipart.
    var supportsMultipart: Bool {
        switch self {
        case .post, .put, .patch, .connect:
            return true
        default:
            return false
        }
    }
}

// MARK: - MoyaProvider

/// Internal extension to keep the inner-workings outside the main Moya.swift file.
public extension MoyaProvider {
    
    /// Performs normal requests using native swift concurrency.
    func requestNormal(_ target: Target) async throws -> Moya.Response {
        
        let endpoint = self.endpoint(target)
        
        let stubBehavior = self.stubClosure(target)
        
        let requestMapping = try MoyaProvider.defaultAsyncRequestMapping(for: endpoint)
        
        let performedRequest = try await performRequest(
            target,
            request: requestMapping,
            endpoint: endpoint
        )
        
        
        return performedRequest
        
    }
    
    /// Performs normal requests.
    func requestNormal(_ target: Target, callbackQueue: DispatchQueue?, progress: Moya.ProgressBlock?, completion: @escaping Moya.Completion) -> Cancellable {
        let endpoint = self.endpoint(target)
        let stubBehavior = self.stubClosure(target)
        let cancellableToken = CancellableWrapper()

        // Allow plugins to modify response
        let pluginsWithCompletion: Moya.Completion = { result in
            let processedResult = self.plugins.reduce(result) { $1.process($0, target: target) }
            completion(processedResult)
        }

        if trackInflights {
            var inflightCompletionBlocks = self.inflightRequests[endpoint]
            inflightCompletionBlocks?.append(pluginsWithCompletion)
            self.internalInflightRequests[endpoint] = inflightCompletionBlocks

            if inflightCompletionBlocks != nil {
                return cancellableToken
            } else {
                self.internalInflightRequests[endpoint] = [pluginsWithCompletion]
            }
        }

        let performNetworking = { (requestResult: Result<URLRequest, MoyaError>) in
            if cancellableToken.isCancelled {
                self.cancelCompletion(pluginsWithCompletion, target: target)
                return
            }

            var request: URLRequest!

            switch requestResult {
            case .success(let urlRequest):
                request = urlRequest
            case .failure(let error):
                pluginsWithCompletion(.failure(error))
                return
            }

            let networkCompletion: Moya.Completion = { result in
              if self.trackInflights {
                self.inflightRequests[endpoint]?.forEach { $0(result) }
                self.internalInflightRequests.removeValue(forKey: endpoint)
              } else {
                pluginsWithCompletion(result)
              }
            }

            cancellableToken.innerCancellable = self.performRequest(target, request: request, callbackQueue: callbackQueue, progress: progress, completion: networkCompletion, endpoint: endpoint, stubBehavior: stubBehavior)
        }

        requestClosure(endpoint, performNetworking)

        return cancellableToken
    }

    // swiftlint:disable:next function_parameter_count
    private func performRequest(_ target: Target, request: URLRequest, callbackQueue: DispatchQueue?, progress: Moya.ProgressBlock?, completion: @escaping Moya.Completion, endpoint: Endpoint, stubBehavior: Moya.StubBehavior) -> Cancellable {

        let onSendUploadMultipart: (MultipartFormData) -> Cancellable = { multipartFormData in
            guard !multipartFormData.parts.isEmpty && endpoint.method.supportsMultipart else {
                fatalError("\(target) is not a multipart upload target.")
            }
            return self.sendUploadMultipart(target, request: request, callbackQueue: callbackQueue, multipartFormData: multipartFormData, progress: progress, completion: completion)
        }

        switch stubBehavior {
        case .never:
            switch endpoint.task {
            case .requestPlain, .requestData, .requestJSONEncodable, .requestCustomJSONEncodable, .requestParameters, .requestCompositeData, .requestCompositeParameters:
                return self.sendRequest(target, request: request, callbackQueue: callbackQueue, progress: progress, completion: completion)
            case .uploadFile(let file):
                return self.sendUploadFile(target, request: request, callbackQueue: callbackQueue, file: file, progress: progress, completion: completion)
            case .uploadMultipartFormData(let multipartFormData), .uploadCompositeMultipartFormData(let multipartFormData, _):
                return onSendUploadMultipart(multipartFormData)
            case .uploadMultipart(let multipartFormBodyParts), .uploadCompositeMultipart(let multipartFormBodyParts, _):
                return onSendUploadMultipart(MultipartFormData(parts: multipartFormBodyParts))
            case .downloadDestination(let destination), .downloadParameters(_, _, let destination):
                return self.sendDownloadRequest(target, request: request, callbackQueue: callbackQueue, destination: destination, progress: progress, completion: completion)
            }
        default:
            return self.stubRequest(target, request: request, callbackQueue: callbackQueue, completion: completion, endpoint: endpoint, stubBehavior: stubBehavior)
        }
    }
    
    private func performRequest(
        _ target: Target,
        request: URLRequest,
        endpoint: Endpoint
    ) async throws -> Moya.Response {
        
        let onSendUploadMultipart: (MultipartFormData) async throws -> Moya.Response = { multipartFormData in
            guard !multipartFormData.parts.isEmpty && endpoint.method.supportsMultipart else {
                fatalError("\(target) is not a multipart upload target.")
            }
            
            return try await self.sendUploadMultipart(target, request: request, multipartFormData: multipartFormData)
        }
        
        switch endpoint.task {
            case .requestPlain, .requestData, .requestJSONEncodable,
                    .requestCustomJSONEncodable, .requestParameters, .requestCompositeData,
                    .requestCompositeParameters:
                return try await self.sendRequest(target, request: request)
            case .uploadFile(let file):
                return try await self.sendUploadFile(target, request: request, file: file)
            case .uploadMultipartFormData(let multipartFormData), .uploadCompositeMultipartFormData(let multipartFormData, _):
                return try await onSendUploadMultipart(multipartFormData)
            case .uploadMultipart(let multipartFormBodyParts), .uploadCompositeMultipart(let multipartFormBodyParts, _):
                return try await onSendUploadMultipart(MultipartFormData(parts: multipartFormBodyParts))
            case .downloadDestination(let destination), .downloadParameters(parameters: _, encoding: _, let destination):
                return try await self.sendDownloadRequest(target, request: request, destination: destination)
        }
        
    }

    func cancelCompletion(_ completion: Moya.Completion, target: Target) {
        let error = MoyaError.underlying(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil), nil)
        plugins.forEach { $0.didReceive(.failure(error), target: target) }
        completion(.failure(error))
    }

    /// Creates a function which, when called, executes the appropriate stubbing behavior for the given parameters.
    final func createStubFunction(_ token: CancellableToken, forTarget target: Target, withCompletion completion: @escaping Moya.Completion, endpoint: Endpoint, plugins: [PluginType], request: URLRequest) -> (() -> Void) { // swiftlint:disable:this function_parameter_count
        return {
            if token.isCancelled {
                self.cancelCompletion(completion, target: target)
                return
            }

            let validate = { (response: Moya.Response) -> Result<Moya.Response, MoyaError> in
                let validCodes = target.validationType.statusCodes
                guard !validCodes.isEmpty else { return .success(response) }
                if validCodes.contains(response.statusCode) {
                    return .success(response)
                } else {
                    let statusError = MoyaError.statusCode(response)
                    let error = MoyaError.underlying(statusError, response)
                    return .failure(error)
                }
            }

            switch endpoint.sampleResponseClosure() {
            case .networkResponse(let statusCode, let data):
                let response = Moya.Response(statusCode: statusCode, data: data, request: request, response: nil)
                let result = validate(response)
                plugins.forEach { $0.didReceive(result, target: target) }
                completion(result)
            case .response(let customResponse, let data):
                let response = Moya.Response(statusCode: customResponse.statusCode, data: data, request: request, response: customResponse)
                let result = validate(response)
                plugins.forEach { $0.didReceive(result, target: target) }
                completion(result)
            case .networkError(let error):
                let error = MoyaError.underlying(error, nil)
                plugins.forEach { $0.didReceive(.failure(error), target: target) }
                completion(.failure(error))
            }
        }
    }

    /// Notify all plugins that a stub is about to be performed. You must call this if overriding `stubRequest`.
    final func notifyPluginsOfImpendingStub(for request: URLRequest, target: Target) -> URLRequest {
        let alamoRequest = session.request(request)
        alamoRequest.cancel()

        let preparedRequest = plugins.reduce(request) { $1.prepare($0, target: target) }

        let stubbedAlamoRequest = RequestTypeWrapper(request: alamoRequest, urlRequest: preparedRequest)
        plugins.forEach { $0.willSend(stubbedAlamoRequest, target: target) }

        return preparedRequest
    }
}

private extension MoyaProvider {
    
    private func interceptRequest(request: URLRequest, with target: Target) async throws -> URLRequest {
        let preparedResult = try await asyncPlugins.asyncReduce(request) {
            try await $1.prepare($0, target: target)
        }
        return preparedResult
    }
    
    private func setup(
        urlRequest: URLRequest,
        with target: Target
    ) async throws -> URLRequest {
        
        let preparedRequest = try await interceptRequest(request: urlRequest, with: target)

        self.asyncPlugins.forEach { $0.willSend(urlRequest, target: target) }
        
        return preparedRequest
    }
    
    
    private func interceptor(target: Target) -> MoyaRequestInterceptor {
        return MoyaRequestInterceptor(prepare: { [weak self] urlRequest in
            return self?.plugins.reduce(urlRequest) { $1.prepare($0, target: target) } ?? urlRequest
       })
    }

    private func setup(interceptor: MoyaRequestInterceptor, with target: Target, and request: Request) {
        interceptor.willSend = { [weak self, weak request] urlRequest in
            guard let self = self, let request = request else { return }

            let stubbedAlamoRequest = RequestTypeWrapper(request: request, urlRequest: urlRequest)
            self.plugins.forEach { $0.willSend(stubbedAlamoRequest, target: target) }
        }
    }

    func sendUploadMultipart(_ target: Target, request: URLRequest, callbackQueue: DispatchQueue?, multipartFormData: MultipartFormData, progress: Moya.ProgressBlock? = nil, completion: @escaping Moya.Completion) -> CancellableToken {
        let formData = RequestMultipartFormData(fileManager: multipartFormData.fileManager, boundary: multipartFormData.boundary)
        formData.applyMoyaMultipartFormData(multipartFormData)

        let interceptor = self.interceptor(target: target)
        let uploadRequest: UploadRequest = session.requestQueue.sync {
            let uploadRequest = session.upload(multipartFormData: formData, with: request, interceptor: interceptor)
            setup(interceptor: interceptor, with: target, and: uploadRequest)

            return uploadRequest
        }

        let validationCodes = target.validationType.statusCodes
        let validatedRequest = validationCodes.isEmpty ? uploadRequest : uploadRequest.validate(statusCode: validationCodes)
        return sendAlamofireRequest(validatedRequest, target: target, callbackQueue: callbackQueue, progress: progress, completion: completion)
    }
    
    func sendUploadMultipart(_ target: Target, request: URLRequest, multipartFormData: MultipartFormData) async throws -> Moya.Response {
        
        let formData = RequestMultipartFormData(
            fileManager: multipartFormData.fileManager,
            boundary: multipartFormData.boundary
        )
        
        let preparedRequest = try await setup(urlRequest: request, with: target)
        
        let uploadRequest: UploadRequest = AF.upload(multipartFormData: formData, with: preparedRequest)
        
        return try await withCheckedThrowingContinuation { continuation in
            sendAlamofireRequest(
                uploadRequest,
                target: target,
                callbackQueue: nil,
                progress: nil
            ) { result in
                switch result {
                    case .success(let response):
                        continuation.resume(returning: response)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                }
            }
        }
    }

    func sendUploadFile(_ target: Target, request: URLRequest, callbackQueue: DispatchQueue?, file: URL, progress: ProgressBlock? = nil, completion: @escaping Completion) -> CancellableToken {
        let interceptor = self.interceptor(target: target)
        let uploadRequest: UploadRequest = session.requestQueue.sync {
            let uploadRequest = session.upload(file, with: request, interceptor: interceptor)
            setup(interceptor: interceptor, with: target, and: uploadRequest)

            return uploadRequest
        }

        let validationCodes = target.validationType.statusCodes
        let alamoRequest = validationCodes.isEmpty ? uploadRequest : uploadRequest.validate(statusCode: validationCodes)
        return sendAlamofireRequest(alamoRequest, target: target, callbackQueue: callbackQueue, progress: progress, completion: completion)
    }
    
    func sendUploadFile(_ target: Target, request: URLRequest, file: URL) async throws -> Moya.Response {
        
        let preparedRequest = try await setup(urlRequest: request, with: target)
        
        let uploadRequest = Session().upload(file, with: request, interceptor: nil)
        
        return try await withCheckedThrowingContinuation { continuation in
            sendAlamofireRequest(uploadRequest, target: target, callbackQueue: nil, progress: nil) { result in
                switch result {
                    case .success(let response):
                        continuation.resume(returning: response)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                }
            }
        }
        
    }

    func sendDownloadRequest(_ target: Target, request: URLRequest, callbackQueue: DispatchQueue?, destination: @escaping DownloadDestination, progress: ProgressBlock? = nil, completion: @escaping Completion) -> CancellableToken {
        let interceptor = self.interceptor(target: target)
        let downloadRequest: DownloadRequest = session.requestQueue.sync {
            let downloadRequest = session.download(request, interceptor: interceptor, to: destination)
            setup(interceptor: interceptor, with: target, and: downloadRequest)

            return downloadRequest
        }

        let validationCodes = target.validationType.statusCodes
        let alamoRequest = validationCodes.isEmpty ? downloadRequest : downloadRequest.validate(statusCode: validationCodes)
        return sendAlamofireRequest(alamoRequest, target: target, callbackQueue: callbackQueue, progress: progress, completion: completion)
    }
    
    func sendDownloadRequest(_ target: Target, request: URLRequest, destination: @escaping DownloadDestination) async throws -> Moya.Response {
        
        let preparedRequest = try await setup(urlRequest: request, with: target)
        
        let downloadRequest =  AF.download(preparedRequest)
        
        return try await withCheckedThrowingContinuation { continuation in
            sendAlamofireRequest(downloadRequest, target: target, callbackQueue: nil, progress: nil) { result in
                switch result {
                    case .success(let response):
                        continuation.resume(returning: response)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                }
            }
        }
    }

    func sendRequest(_ target: Target, request: URLRequest, callbackQueue: DispatchQueue?, progress: Moya.ProgressBlock?, completion: @escaping Moya.Completion) -> CancellableToken {
        let interceptor = self.interceptor(target: target)
        let initialRequest: DataRequest = session.requestQueue.sync {
            let initialRequest = session.request(request, interceptor: interceptor)
            setup(interceptor: interceptor, with: target, and: initialRequest)

            return initialRequest
        }

        let validationCodes = target.validationType.statusCodes
        let alamoRequest = validationCodes.isEmpty ? initialRequest : initialRequest.validate(statusCode: validationCodes)
        return sendAlamofireRequest(alamoRequest, target: target, callbackQueue: callbackQueue, progress: progress, completion: completion)
    }
    
    
    func sendRequest(_ target: Target, request: URLRequest) async throws -> Moya.Response {
        
        let preparedRequest = try await setup(urlRequest: request, with: target)
        
        let alamoRequest =  AF.request(preparedRequest)
        
        return try await withCheckedThrowingContinuation { continuation in
            sendAlamofireRequest(alamoRequest, target: target, callbackQueue: nil, progress: nil) { result in
                switch result {
                    case .success(let response):
                        continuation.resume(returning: response)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                }
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    @discardableResult
    func sendAlamofireRequest<T>(_ alamoRequest: T, target: Target, callbackQueue: DispatchQueue?, progress progressCompletion: Moya.ProgressBlock?, completion: @escaping Moya.Completion) -> CancellableToken where T: Requestable, T: Request {
        // Give plugins the chance to alter the outgoing request
        let plugins = self.plugins
        var progressAlamoRequest = alamoRequest
        let progressClosure: (Progress) -> Void = { progress in
            let sendProgress: () -> Void = {
                progressCompletion?(ProgressResponse(progress: progress))
            }

            if let callbackQueue = callbackQueue {
                callbackQueue.async(execute: sendProgress)
            } else {
                sendProgress()
            }
        }

        // Perform the actual request
        if progressCompletion != nil {
            switch progressAlamoRequest {
            case let downloadRequest as DownloadRequest:
                if let downloadRequest = downloadRequest.downloadProgress(closure: progressClosure) as? T {
                    progressAlamoRequest = downloadRequest
                }
            case let uploadRequest as UploadRequest:
                if let uploadRequest = uploadRequest.uploadProgress(closure: progressClosure) as? T {
                    progressAlamoRequest = uploadRequest
                }
            case let dataRequest as DataRequest:
                if let dataRequest = dataRequest.downloadProgress(closure: progressClosure) as? T {
                    progressAlamoRequest = dataRequest
                }
            default: break
            }
        }

        let completionHandler: RequestableCompletion = { response, request, data, error in
            let result = convertResponseToResult(response, request: request, data: data, error: error)
            // Inform all plugins about the response
            plugins.forEach { $0.didReceive(result, target: target) }
            if let progressCompletion = progressCompletion {
                let value = try? result.get()
                switch progressAlamoRequest {
                case let downloadRequest as DownloadRequest:
                    progressCompletion(ProgressResponse(progress: downloadRequest.downloadProgress, response: value))
                case let uploadRequest as UploadRequest:
                    progressCompletion(ProgressResponse(progress: uploadRequest.uploadProgress, response: value))
                case let dataRequest as DataRequest:
                    progressCompletion(ProgressResponse(progress: dataRequest.downloadProgress, response: value))
                default:
                    progressCompletion(ProgressResponse(response: value))
                }
            }
            completion(result)
        }

        progressAlamoRequest = progressAlamoRequest.response(callbackQueue: callbackQueue, completionHandler: completionHandler)

        progressAlamoRequest.resume()

        return CancellableToken(request: progressAlamoRequest)
    }
}
