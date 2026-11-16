import AgentKit
import CloudKit
import Foundation
import XCTest
@testable import AgentSystem

final class CloudLinkTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func assertUnavailable(_ body: () async throws -> Void, _ name: String) async {
        do {
            try await body()
            XCTFail("\(name) reached CloudKit")
        } catch {
            XCTAssertEqual(error as? CloudLinkError, .unavailable, name)
        }
    }

    func testEveryCallIsUnavailableWithoutTheICloudEntitlement() async throws {
        XCTAssertFalse(CloudLink.isAvailable, "the test runner, swift run and ad-hoc builds have no iCloud entitlement")
        let directory = try TempDirectory()
        let url = directory.url.appendingPathComponent("Hoply/icloud-link.json")
        let link = CloudLink(stateURL: url)
        let snapshot = RemoteSnapshot(device: link.device, away: true, updatedAt: t0)
        let request = RemoteRequest(id: "re-1", kind: .reply, device: link.device, session: "claude-code:s",
                                    agent: "claude-code", createdAt: t0, expiresAt: t0)
        await assertUnavailable({ _ = try await link.accountStatus() }, "accountStatus")
        await assertUnavailable({ try await link.prepare() }, "prepare")
        await assertUnavailable({ try await link.publish(snapshot) }, "publish")
        await assertUnavailable({ try await link.open(request) }, "open")
        await assertUnavailable({ try await link.close(requestID: "re-1") }, "close")
        await assertUnavailable({ _ = try await link.fetchAnswers() }, "fetchAnswers")
        await assertUnavailable({ try await link.acknowledge(["a-1"]) }, "acknowledge")
        await assertUnavailable({ try await link.acknowledge([]) }, "acknowledge nothing")
        await assertUnavailable({ try await link.withdraw() }, "withdraw")
        let open = await link.openRequestIDs
        XCTAssertEqual(open, [], "a failed open is not remembered")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing is written without iCloud")
    }

    func testTheEntitlementCheckNeedsOurContainerAndCloudKit() {
        let container = RemoteSchema.containerID
        XCTAssertTrue(CloudLink.isEntitled(containers: [container], services: ["CloudKit"]))
        XCTAssertTrue(CloudLink.isEntitled(containers: ["iCloud.other", container] as NSArray,
                                           services: ["CloudDocuments", "CloudKit"] as NSArray))
        XCTAssertFalse(CloudLink.isEntitled(containers: ["iCloud.other"], services: ["CloudKit"]))
        XCTAssertFalse(CloudLink.isEntitled(containers: [container], services: ["CloudDocuments"]))
        XCTAssertFalse(CloudLink.isEntitled(containers: container, services: "*"), "a profile's raw values never sign")
        XCTAssertFalse(CloudLink.isEntitled(containers: nil, services: nil))
    }

    func testCloudKitErrorsMapToTheLinkErrors() {
        XCTAssertEqual(CloudLinkError(CKError(.notAuthenticated)), .noAccount)
        XCTAssertEqual(CloudLinkError(CKError(.accountTemporarilyUnavailable)), .noAccount)
        XCTAssertEqual(CloudLinkError(CKError(.managedAccountRestricted)), .noAccount)
        XCTAssertEqual(CloudLinkError(CKError(.networkUnavailable)), .network)
        XCTAssertEqual(CloudLinkError(CKError(.networkFailure)), .network)
        XCTAssertEqual(CloudLinkError(CKError(.serverResponseLost)), .network)
        XCTAssertEqual(CloudLinkError(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7.0])),
                       .limited(retryAfter: 7))
        XCTAssertEqual(CloudLinkError(CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 30)])),
                       .limited(retryAfter: 30))
        XCTAssertEqual(CloudLinkError(CKError(.zoneBusy)), .limited(retryAfter: nil))
        XCTAssertEqual(CloudLinkError(CKError(.quotaExceeded)), .quotaExceeded)
        XCTAssertEqual(CloudLinkError(CKError(.missingEntitlement)), .unavailable)
        XCTAssertEqual(CloudLinkError(CKError(.badContainer)), .unavailable)
        XCTAssertEqual(CloudLinkError(CloudLinkError.network), .network)
        guard case .other = CloudLinkError(CKError(.internalError)) else { return XCTFail("internal error") }
        guard case .other = CloudLinkError(CocoaError(.fileWriteNoPermission)) else { return XCTFail("not CloudKit") }
    }

    func testAPartialFailureReportsItsCause() {
        func partial(_ codes: [CKError.Code]) -> CKError {
            var errors: [CKRecord.ID: any Error] = [:]
            for (index, code) in codes.enumerated() { errors[CKRecord.ID(recordName: "r\(index)")] = CKError(code) }
            return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errors])
        }
        XCTAssertEqual(CloudLinkError(partial([.batchRequestFailed, .quotaExceeded, .batchRequestFailed])),
                       .quotaExceeded, "batchRequestFailed only points at the item that failed")
        XCTAssertEqual(CloudLinkError(partial([.networkFailure, .notAuthenticated])), .noAccount)
        guard case .other = CloudLinkError(partial([.batchRequestFailed])) else { return XCTFail("no cause") }
    }

    func testAMissingZoneIsRecognised() {
        XCTAssertTrue(CloudLink.zoneMissing(CKError(.zoneNotFound)))
        XCTAssertTrue(CloudLink.zoneMissing(CKError(.userDeletedZone)))
        XCTAssertTrue(CloudLink.zoneMissing(CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "a"): CKError(.zoneNotFound)] as [CKRecord.ID: any Error],
        ])))
        XCTAssertFalse(CloudLink.zoneMissing(CKError(.unknownItem)))
        XCTAssertFalse(CloudLink.zoneMissing(CocoaError(.fileNoSuchFile)))
    }

    func testRecordsKeepContentInEncryptedValuesOnly() throws {
        let zone = CKRecordZone.ID(zoneName: RemoteSchema.zoneName, ownerName: CKCurrentUserDefaultName)
        let request = RemoteRequest(id: "re-1", kind: .reply, device: "mac-1", session: "claude-code:s",
                                    agent: "claude-code", message: "x", createdAt: t0, expiresAt: t0)
        let image = try RemoteSchema.record(request)
        let record = CloudLink.record(from: image, zone: zone)
        XCTAssertEqual(record.recordType, RemoteSchema.RecordType.request)
        XCTAssertEqual(record.recordID.recordName, "re-1")
        XCTAssertEqual(record.recordID.zoneID.zoneName, "Hoply")
        let kind: String? = record[RemoteSchema.Field.kind]
        let createdAt: Date? = record[RemoteSchema.Field.createdAt]
        let version: Int? = record[RemoteSchema.Field.version]
        let plainPayload: Data? = record[RemoteSchema.Field.payload]
        let payload: Data? = record.encryptedValues[RemoteSchema.Field.payload]
        XCTAssertEqual(kind, "reply")
        XCTAssertEqual(createdAt, t0)
        XCTAssertEqual(version, RemoteSchema.version)
        XCTAssertNil(plainPayload, "the payload is never a plain field")
        XCTAssertEqual(payload, image.payload)
        XCTAssertEqual(CloudLink.image(of: record), image)
        XCTAssertEqual(RemoteSchema.request(from: CloudLink.image(of: record)), request)

        let snapshot = CloudLink.record(from: try RemoteSchema.record(RemoteSnapshot(device: "mac-1", away: false,
                                                                                    updatedAt: t0)), zone: zone)
        let snapshotKind: String? = snapshot[RemoteSchema.Field.kind]
        XCTAssertNil(snapshotKind)
        XCTAssertEqual(snapshot.recordID.recordName, "snapshot-mac-1")
    }

    func testStateKeepsTheDeviceAcrossLaunches() async throws {
        let directory = try TempDirectory()
        let url = directory.url.appendingPathComponent("Hoply/icloud-link.json")
        let state = CloudLinkState(device: "mac-1", zoneReady: true, subscriptionReady: true, changeToken: Data([1, 2]),
                                   openRequests: ["re-1"])
        try state.save(to: url)
        XCTAssertEqual(CloudLinkState.load(from: url), state)
        let link = CloudLink(stateURL: url)
        XCTAssertEqual(link.device, "mac-1")
        let open = await link.openRequestIDs
        XCTAssertEqual(open, ["re-1"], "left over from the last run; prepare() deletes them")

        try directory.write("Hoply/icloud-link.json", #"{"device": 5, "zoneReady": "yes", "openRequests": ["a"]}"#)
        let lenient = CloudLinkState.load(from: url)
        XCTAssertFalse(lenient.zoneReady)
        XCTAssertEqual(lenient.openRequests, ["a"])
        XCTAssertFalse(lenient.device.isEmpty)
        try directory.write("Hoply/icloud-link.json", "not json")
        XCTAssertNotEqual(CloudLinkState.load(from: url).device, "mac-1")
        let missing = directory.url.appendingPathComponent("none.json")
        XCTAssertNotEqual(CloudLink(stateURL: missing).device, CloudLink(stateURL: missing).device,
                          "nothing saved yet: no device id to keep")
    }

    func testOnlyTheAnswerSubscriptionsPushesCount() {
        XCTAssertFalse(CloudLink.isAnswerNotification([:]))
        XCTAssertFalse(CloudLink.isAnswerNotification(["aps": ["content-available": 1]]))
    }
}

final class ProfileEntitlementsTests: XCTestCase {
    private let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/profile-entitlements.sh").path
    private let container = RemoteSchema.containerID
    private let bundle = "com.coolcraftcoders.hoply"

    private struct Run {
        var status: Int32
        var output: Data
        var error: String
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: out, error: String(decoding: err, as: UTF8.self))
    }

    private func profile(_ entitlements: [String: Any], allDevices: Bool, in directory: TempDirectory,
                         name: String) throws -> String {
        var plist: [String: Any] = ["Name": "synthetic", "Entitlements": entitlements]
        if allDevices {
            plist["ProvisionsAllDevices"] = true
        } else {
            plist["ProvisionedDevices"] = ["00000000-0000000000000000"]
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: directory.url.appendingPathComponent("\(name).plist"))
        if !FileManager.default.fileExists(atPath: directory.path("key.pem")) {
            let made = try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem",
                                                    "-out", "cert.pem", "-subj", "/CN=hoply-test", "-days", "1"],
                               in: directory.url)
            XCTAssertEqual(made.status, 0, made.error)
        }
        let signed = try run("/usr/bin/openssl", ["smime", "-sign", "-binary", "-nodetach", "-in", "\(name).plist",
                                                  "-signer", "cert.pem", "-inkey", "key.pem", "-outform", "der",
                                                  "-out", "\(name).provisionprofile"], in: directory.url)
        XCTAssertEqual(signed.status, 0, signed.error)
        return directory.path("\(name).provisionprofile")
    }

    private func entitlements(_ profile: String, in directory: TempDirectory,
                              file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let result = try run("/bin/bash", [script, profile, container, bundle], in: directory.url)
        XCTAssertEqual(result.status, 0, result.error, file: file, line: line)
        let parsed = try PropertyListSerialization.propertyList(from: result.output, format: nil)
        return try XCTUnwrap(parsed as? [String: Any], file: file, line: line)
    }

    private var developerID: [String: Any] {
        ["com.apple.application-identifier": "ABCDE12345.\(bundle)",
         "com.apple.developer.team-identifier": "ABCDE12345",
         "com.apple.developer.icloud-container-identifiers": [container],
         "com.apple.developer.icloud-container-development-container-identifiers": [container],
         "com.apple.developer.icloud-services": "*",
         "com.apple.developer.icloud-container-environment": ["Development", "Production"],
         "com.apple.developer.aps-environment": "production",
         "keychain-access-groups": ["ABCDE12345.*"],
         "com.apple.security.get-task-allow": false]
    }

    func testDeveloperIDProfileGivesProductionCloudKitOnly() throws {
        let directory = try TempDirectory()
        let result = try entitlements(try profile(developerID, allDevices: true, in: directory, name: "devid"),
                                      in: directory)
        XCTAssertEqual(Set(result.keys), ["com.apple.application-identifier", "com.apple.developer.team-identifier",
                                          "com.apple.developer.icloud-container-identifiers",
                                          "com.apple.developer.icloud-services",
                                          "com.apple.developer.icloud-container-environment",
                                          "com.apple.developer.aps-environment"])
        XCTAssertEqual(result["com.apple.application-identifier"] as? String, "ABCDE12345.\(bundle)")
        XCTAssertEqual(result["com.apple.developer.team-identifier"] as? String, "ABCDE12345")
        XCTAssertEqual(result["com.apple.developer.icloud-container-identifiers"] as? [String], [container])
        XCTAssertEqual(result["com.apple.developer.icloud-services"] as? [String], ["CloudKit"], "never the profile's *")
        XCTAssertEqual(result["com.apple.developer.icloud-container-environment"] as? String, "Production")
        XCTAssertEqual(result["com.apple.developer.aps-environment"] as? String, "production")
    }

    func testDevelopmentProfileGivesDevelopment() throws {
        let directory = try TempDirectory()
        var development = developerID
        development["com.apple.application-identifier"] = "ABCDE12345.*"
        development["com.apple.developer.icloud-services"] = ["CloudKit", "CloudDocuments"]
        development["com.apple.developer.aps-environment"] = "development"
        development["com.apple.developer.icloud-container-identifiers"] = ["iCloud.other", container]
        let result = try entitlements(try profile(development, allDevices: false, in: directory, name: "dev"),
                                      in: directory)
        XCTAssertEqual(result["com.apple.application-identifier"] as? String, "ABCDE12345.\(bundle)",
                       "a wildcard App ID gets the bundle id")
        XCTAssertEqual(result["com.apple.developer.icloud-container-identifiers"] as? [String], [container])
        XCTAssertEqual(result["com.apple.developer.icloud-services"] as? [String], ["CloudKit"])
        XCTAssertEqual(result["com.apple.developer.icloud-container-environment"] as? String, "Development")
        XCTAssertEqual(result["com.apple.developer.aps-environment"] as? String, "development")

        development["com.apple.developer.aps-environment"] = nil
        let quiet = try entitlements(try profile(development, allDevices: false, in: directory, name: "nopush"),
                                     in: directory)
        XCTAssertNil(quiet["com.apple.developer.aps-environment"], "no push: the Mac polls")
    }

    func testProfilesThatCantSignTheLinkAreRefused() throws {
        let directory = try TempDirectory()
        var cases: [(String, [String: Any], Bool)] = []
        var other = developerID
        other["com.apple.application-identifier"] = "ABCDE12345.com.example.other"
        cases.append(("another app", other, true))
        var noContainer = developerID
        noContainer["com.apple.developer.icloud-container-identifiers"] = ["iCloud.other"]
        cases.append(("no container", noContainer, true))
        var noCloudKit = developerID
        noCloudKit["com.apple.developer.icloud-services"] = ["CloudDocuments"]
        cases.append(("no CloudKit", noCloudKit, true))
        var developmentOnly = developerID
        developmentOnly["com.apple.developer.icloud-container-environment"] = ["Development"]
        cases.append(("no Production", developmentOnly, true))
        var noTeam = developerID
        noTeam["com.apple.developer.team-identifier"] = nil
        cases.append(("no team", noTeam, true))
        for (index, (name, values, allDevices)) in cases.enumerated() {
            let path = try profile(values, allDevices: allDevices, in: directory, name: "bad\(index)")
            let result = try run("/bin/bash", [script, path, container, bundle], in: directory.url)
            XCTAssertEqual(result.status, 1, name)
            XCTAssertEqual(result.output, Data(), name)
            XCTAssertFalse(result.error.isEmpty, name)
        }
        let plain = try run("/bin/bash", [script, directory.path("bad0.plist"), container, bundle], in: directory.url)
        XCTAssertEqual(plain.status, 1, "an unsigned plist is not a profile")
        XCTAssertEqual(try run("/bin/bash", [script], in: directory.url).status, 2)
    }

    func testBuildScriptPassesOurContainer() throws {
        let build = script.replacingOccurrences(of: "profile-entitlements.sh", with: "build-app.sh")
        let text = try String(contentsOfFile: build, encoding: .utf8)
        XCTAssertTrue(text.contains("scripts/profile-entitlements.sh \"$PROFILE\" \(container) "),
                      "build-app.sh signs for RemoteSchema.containerID")
    }
}
