import Foundation

/// Only the read-only list request may retry inside an authenticated session.
public struct ProtocolListRetryPolicy {
    public private(set) var retries = 0
    public let maximumRetries = 2
    public init() {}
    public mutating func takeRetry(authenticated: Bool, connected: Bool, writePending: Bool) -> Bool {
        guard authenticated, connected, !writePending, retries < maximumRetries else { return false }
        retries += 1
        return true
    }
}
