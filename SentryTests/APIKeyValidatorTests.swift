import XCTest
import MCP
@testable import SentryKit

/// Pure `HTTPRequestValidator` logic — no real socket, no real Keychain, the
/// expected key is passed in directly (see `APIKeyValidator`'s doc comment
/// on why it's dependency-injected rather than reading `MCPRemoteAccessKey`
/// itself).
final class APIKeyValidatorTests: XCTestCase {

    private let context = HTTPValidationContext(httpMethod: "POST")

    private func request(authorization: String?) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let authorization {
            headers["Authorization"] = authorization
        }
        return HTTPRequest(method: "POST", headers: headers, body: nil, path: "/mcp")
    }

    func testRejectsWhenNoKeyIsConfigured() {
        let validator = APIKeyValidator(expectedKey: nil)
        let response = validator.validate(request(authorization: "Bearer anything"), context: context)
        XCTAssertEqual(response?.statusCode, 401)
    }

    func testRejectsMissingAuthorizationHeader() {
        let validator = APIKeyValidator(expectedKey: "correct-key")
        let response = validator.validate(request(authorization: nil), context: context)
        XCTAssertEqual(response?.statusCode, 401)
    }

    func testRejectsNonBearerAuthorizationHeader() {
        let validator = APIKeyValidator(expectedKey: "correct-key")
        let response = validator.validate(request(authorization: "Basic dXNlcjpwYXNz"), context: context)
        XCTAssertEqual(response?.statusCode, 401)
    }

    func testRejectsWrongBearerToken() {
        let validator = APIKeyValidator(expectedKey: "correct-key")
        let response = validator.validate(request(authorization: "Bearer wrong-key"), context: context)
        XCTAssertEqual(response?.statusCode, 401)
    }

    func testRejectsTokenThatIsAPrefixOfTheRealKey() {
        let validator = APIKeyValidator(expectedKey: "correct-key")
        let response = validator.validate(request(authorization: "Bearer correct"), context: context)
        XCTAssertEqual(response?.statusCode, 401)
    }

    func testAcceptsCorrectBearerToken() {
        let validator = APIKeyValidator(expectedKey: "correct-key")
        let response = validator.validate(request(authorization: "Bearer correct-key"), context: context)
        XCTAssertNil(response, "nil means the validator passed the request through")
    }
}
