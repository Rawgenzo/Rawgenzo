import XCTest
import CoreImage
@testable import RAWCore

final class MCPConfigFileTests: XCTestCase {
    private func json(_ d: Data?) -> [String: Any]? {
        d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    private func entry(_ d: Data?) -> [String: Any]? {
        (json(d)?["mcpServers"] as? [String: Any])?["rawgenzo"] as? [String: Any]
    }

    func testCreatesWhenMissing() {
        let d = MCPConfigFile.updated(nil, rawdev: "/Applications/Rawgenzo.app/Contents/MacOS/rawdev")
        XCTAssertEqual(entry(d)?["command"] as? String, "/Applications/Rawgenzo.app/Contents/MacOS/rawdev")
        XCTAssertEqual(entry(d)?["args"] as? [String], ["mcp"])
    }

    func testKeepsExistingCommandThatExists() {
        let old = Data(#"{"mcpServers":{"rawgenzo":{"command":"/opt/rawdev","args":["mcp","/p","--log","/l"]}}}"#.utf8)
        XCTAssertNil(MCPConfigFile.updated(old, rawdev: "/new/rawdev", fileExists: { $0 == "/opt/rawdev" }))
    }

    func testFollowsLastLaunchedApp() {
        let mine = "/Applications/Rawgenzo.app/Contents/MacOS/rawdev"
        let old = Data(#"{"mcpServers":{"rawgenzo":{"command":"/repo/build/Rawgenzo.app/Contents/MacOS/rawdev","args":["mcp"]}}}"#.utf8)
        XCTAssertEqual(entry(MCPConfigFile.updated(old, rawdev: mine, fileExists: { _ in true }))?["command"] as? String, mine)
        let same = Data(#"{"mcpServers":{"rawgenzo":{"command":"/Applications/Rawgenzo.app/Contents/MacOS/rawdev","args":["mcp"]}}}"#.utf8)
        XCTAssertNil(MCPConfigFile.updated(same, rawdev: mine, fileExists: { _ in true }))
    }

    func testRepointsMissingCommandAndKeepsArgsAndOtherServers() {
        let old = Data(#"{"mcpServers":{"rawgenzo":{"command":"/gone/rawdev","args":["mcp","--log","/l"]},"other":{"command":"x"}}}"#.utf8)
        let d = MCPConfigFile.updated(old, rawdev: "/new/rawdev", fileExists: { _ in false })
        XCTAssertEqual(entry(d)?["command"] as? String, "/new/rawdev")
        XCTAssertEqual(entry(d)?["args"] as? [String], ["mcp", "--log", "/l"])
        XCTAssertNotNil((json(d)?["mcpServers"] as? [String: Any])?["other"])
    }

    func testAddsEntryAndLeavesBrokenJSON() {
        let other = Data(#"{"mcpServers":{"other":{"command":"x"}}}"#.utf8)
        XCTAssertEqual(entry(MCPConfigFile.updated(other, rawdev: "/r", fileExists: { _ in false }))?["command"] as? String, "/r")
        XCTAssertNil(MCPConfigFile.updated(Data("{oops".utf8), rawdev: "/r"))
    }

    func testSharedConfigReadsLastFolder() throws {
        let c = try JSONDecoder().decode(SharedConfig.self, from: Data(#"{"lastFolder":"/x/y"}"#.utf8))
        XCTAssertEqual(c.lastFolder, "/x/y")
        XCTAssertNil(try JSONDecoder().decode(SharedConfig.self, from: Data("{}".utf8)).lastFolder)
    }
}
