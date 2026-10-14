import Foundation

extension JSONDecoder {
    static var vectaStorage: JSONDecoder {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        value.dateDecodingStrategy = .iso8601
        return value
    }
}

extension JSONEncoder {
    static var vectaStorage: JSONEncoder {
        let value = JSONEncoder()
        value.keyEncodingStrategy = .convertToSnakeCase
        value.dateEncodingStrategy = .iso8601
        return value
    }
}
