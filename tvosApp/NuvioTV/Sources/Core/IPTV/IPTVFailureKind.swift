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

    var localizationKey: String {
        switch self {
        case .invalidAddress: return "iptv_error_address"
        case .authentication: return "iptv_error_auth"
        case .invalidContent: return "iptv_error_content"
        case .tooLarge: return "iptv_error_size"
        case .storage: return "iptv_error_storage"
        case .network: return "iptv_error_network"
        case .other: return "iptv_load_error"
        }
    }

    var fallbackMessage: String {
        switch self {
        case .invalidAddress: return "Check the source address and account details."
        case .authentication: return "The provider rejected access. Check your account details."
        case .invalidContent: return "The provider returned data that Live TV could not read."
        case .tooLarge: return "This source is too large to load."
        case .storage: return "Could not save this source securely on this device."
        case .network: return "Could not reach the provider. Check your connection and try again."
        case .other: return "Could not load this source. Please try again."
        }
    }

    private static func status(_ code: Int) -> Self {
        code == 401 || code == 403 ? .authentication : .network
    }
}
