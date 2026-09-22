import XCTest
@testable import RightMouseCore

final class ProtocolTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let request = CommandRequest(context: ActionContext(entryPoint: .container, container: FileReference(url: URL(fileURLWithPath: "/tmp"), kindHint: .directory), selection: []), action: .copyText(format: .path))
        let data = try WireCodec.encoder().encode(request)
        XCTAssertEqual(try RequestValidator.decode(data).requestID, request.requestID)
    }
}
