import Foundation

public enum ProtocolWireError: Error, Equatable {
    case invalidInput
    case malformedResponse
    case unexpectedCommand
    case unexpectedRequestID
    case inconsistentPage
    case conflictingPage
    case sequenceExhausted
    case replayedPacket
}
