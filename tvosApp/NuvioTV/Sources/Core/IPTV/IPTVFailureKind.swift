import Foundation

/// Presentation categories deliberately omit raw URLs, response bodies and
/// transport error descriptions, which can contain account credentials.
enum IPTVFailureKind: Equatable {
    case invalidAddress, authentication, invalidContent, tooLarge, storage, network, other

    static func classify(_ error: Error) -> Self {
        if let error = error as? IPTVPlaylistLoadError {
            switch error {
            case .invalidURL, .invalidSourceID: return .invalidAddress
            case .invalidResponse, .invalidEncoding: return .invalidContent
            case .tooLarge: return .tooLarge
            case .httpStatus(let code): return status(code)
            }
        }
        if let error = error as? IPTVXtreamError {
            switch error {
            case .invalidConfiguration: return .invalidAddress
            case .authenticationFailed: return .authentication
            case .invalidResponse: return .invalidContent
            case .tooLarge: return .tooLarge
            case .httpStatus(let code): return status(code)
            }
        }
        if let error = error as? IPTVStalkerError {
            switch error {
            case .invalidPortal, .invalidMAC: return .invalidAddress
            case .invalidResponse: return .invalidContent
            case .tooLarge: return .tooLarge
            case .httpStatus(let code): return status(code)
            }
        }
        if error is IPTVPlaylistParser.ParserError || error is DecodingError { return .invalidContent }
        if let error = error as? IPTVSourceStoreError {
            switch error {
            case .invalidProfile, .invalidSource, .duplicateID: return .invalidAddress
            case .keychain: return .storage
            }
        }
        if error is URLError { return .network }
        return .other
    }

    private static func status(_ code: Int) -> Self {
        code == 401 || code == 403 ? .authentication : .network
    }
}
