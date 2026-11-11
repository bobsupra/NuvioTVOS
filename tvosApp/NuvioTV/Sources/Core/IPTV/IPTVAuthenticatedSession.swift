import Foundation

/// Used for account API requests, not media playback: provider credentials may
/// appear in query parameters or headers and must not follow cross-origin redirects.
enum IPTVAuthenticatedSession {
    static let shared = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)

    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let original = task.originalRequest?.url, let destination = request.url,
                  IPTVStalkerRedirectGuard.sameOrigin(original, destination) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
