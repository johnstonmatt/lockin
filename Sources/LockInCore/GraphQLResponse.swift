import Foundation

/// A GraphQL answer from Linear or GitHub. Any error means the data can't be trusted, even if some came back.
struct GraphQLResponse<Payload: Decodable>: Decodable {
    struct Problem: Decodable { var message: String }
    var data: Payload?
    var errors: [Problem]?
    var hasErrors: Bool { errors?.isEmpty == false }
}
