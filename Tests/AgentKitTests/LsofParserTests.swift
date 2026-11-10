import XCTest
@testable import AgentKit

final class LsofParserTests: XCTestCase {
    func testParsesListenersWithProcessFields() throws {
        let entries = LsofParser.parse(try Fixture.text("lsof_listen.txt"))
        XCTAssertEqual(entries.map(\.pid), [990, 41210, 41377])

        XCTAssertEqual(entries[0].command, "rapportd")
        XCTAssertEqual(entries[0].parentPID, 1)
        XCTAssertEqual(entries[0].groupID, 990)
        XCTAssertEqual(entries[0].uid, 501)
        XCTAssertEqual(entries[0].listeners, [
            ListeningSocket(port: 50612, family: .ipv4, address: "0.0.0.0"),
            ListeningSocket(port: 50612, family: .ipv6, address: "::"),
        ])
        XCTAssertEqual(entries[0].listeners.map(\.reach), [.allInterfaces, .allInterfaces])

        XCTAssertEqual(entries[1].groupID, 41200)
        XCTAssertEqual(entries[1].parentPID, 41200)
        XCTAssertEqual(entries[1].listeners, [
            ListeningSocket(port: 3000, family: .ipv6, address: "::"),
            ListeningSocket(port: 24678, family: .ipv6, address: "::1"),
        ])
        XCTAssertEqual(entries[1].listeners[1].reach, .loopback)
    }

    func testFoldsRepeatedDescriptorsAndKeepsSpacesInCommands() throws {
        let entry = try XCTUnwrap(LsofParser.parse(try Fixture.text("lsof_listen.txt")).last)
        XCTAssertEqual(entry.command, "Python Helper")
        XCTAssertEqual(entry.listeners, [ListeningSocket(port: 8000, family: .ipv4, address: "127.0.0.1")])
    }

    func testSkipsConnectedSocketsOtherProtocolsAndProcessesWithoutListeners() throws {
        let entries = LsofParser.parse(try Fixture.text("lsof_listen.txt"))
        XCTAssertFalse(entries.contains { $0.pid == 41500 })
        XCTAssertFalse(entries.flatMap(\.listeners).contains { $0.port == 52011 || $0.port == 5432 || $0.port == 5353 })
    }

    func testParsesTheMinimalFieldSet() throws {
        let entries = LsofParser.parse(try Fixture.text("lsof_listen_minimal.txt"))
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].parentPID)
        XCTAssertNil(entries[0].groupID)
        XCTAssertEqual(entries[0].listeners.map(\.family), [.ipv4, .ipv6])
        XCTAssertEqual(entries[1].listeners, [ListeningSocket(port: 4567, family: .ipv4, address: "192.168.1.20")])
        XCTAssertEqual(entries[1].listeners[0].reach, .address)
    }

    func testListenerNames() {
        XCTAssertEqual(LsofParser.listener(type: nil, name: "[::1]:5173"),
                       ListeningSocket(port: 5173, family: .ipv6, address: "::1"))
        XCTAssertEqual(LsofParser.listener(type: "IPv6", name: "*:8080"),
                       ListeningSocket(port: 8080, family: .ipv6, address: "::"))
        XCTAssertNil(LsofParser.listener(type: "IPv4", name: "*:*"))
        XCTAssertNil(LsofParser.listener(type: "IPv4", name: "127.0.0.1:1->127.0.0.1:2"))
        XCTAssertEqual(LsofParser.parse(""), [])
        XCTAssertEqual(LsofParser.parse("garbage\nf1\nn*:80\n"), [])
    }
}
