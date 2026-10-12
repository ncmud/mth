import Foundation
import Testing
import MTH
import MTHClient

struct MNESTests {
    @Test(arguments: ["192.0.2.42", "2001:db8::42", "::1", "::", "::ffff:192.0.2.42"])
    func clientServerExchangeAndUpdates(address: String) throws {
        let serverOutput = EnvironmentDelegate()
        let server = TelnetSession(delegate: serverOutput)
        let clientOutput = FakeClientDelegate()
        let client = TelnetClientSession(delegate: clientOutput, terminalType: "XTERM",
            clientName: "Web gateway", clientVersion: "1.2", charset: "UTF-8", ipAddress: address)
        _ = client.processInput([255, 253, 39])
        _ = server.processInput(clientOutput.allWrittenBytes)
        clientOutput.writtenChunks.removeAll()
        _ = client.processInput(serverOutput.allWrittenBytes)
        let response = clientOutput.allWrittenBytes
        for byte in response { #expect(server.processInput([byte]).isEmpty) }
        #expect(server.environment.ipAddress == address)
        #expect(server.environment.clientName == "Web gateway")
        #expect(server.environment.clientVersion == "1.2")
        #expect(server.terminalType == "XTERM")
        #expect(server.commFlags.contains(.utf8))
        #expect(server.mttsFlags.contains(.mnes))
        clientOutput.writtenChunks.removeAll()
        client.ipAddress = "198.51.100.7"
        client.charset = "ASCII"
        client.mttsFlags = 0
        _ = server.processInput(clientOutput.allWrittenBytes)
        #expect(server.proxy == "198.51.100.7")
        #expect(server.commFlags.contains(.utf8) == false)
        #expect(server.commFlags.contains(.colors256) == false)
        #expect(server.hasMTTS)
    }

    @Test func gatewayThatOnlyAnswersBareSendReportsAnAddress() {
        let output = EnvironmentDelegate()
        let server = TelnetSession(delegate: output)
        _ = server.processInput([255, 251, 39])
        for request in output.writtenChunks where request == [255, 250, 39, 1, 255, 240] {
            let response: [UInt8] = [255, 250, 39, 0, 0] + Array("IPADDRESS".utf8)
                + [1] + Array("2001:db8::42".utf8) + [255, 240]
            _ = server.processInput(response)
        }
        #expect(server.environment.ipAddress == "2001:db8::42")
    }

    @Test func variableNamesRemainCaseSensitive() throws {
        let entries = [NewEnviron.Entry(name: "Client_Name", value: "Mixed"),
                       NewEnviron.Entry(name: "CLIENT_NAME", value: "Upper")]
        let decoded = try #require(NewEnviron.decode(NewEnviron.packet(command: 0, entries: entries)))
        #expect(decoded.entries == entries)
        let output = FakeClientDelegate()
        let client = TelnetClientSession(delegate: output, clientName: "Example")
        _ = client.processInput([255, 253, 39])
        output.writtenChunks.removeAll()
        _ = client.processInput(NewEnviron.packet(command: 1, entries: [
            .init(name: "client_name"), .init(name: "CLIENT_NAME"),
        ]))
        let response = try #require(NewEnviron.decode(output.allWrittenBytes))
        #expect(response.entries == [.init(name: "client_name"), .init(name: "CLIENT_NAME", value: "Example")])
    }

    @Test func userVariablesRetainTheirTypeInRepliesAndUpdates() throws {
        let output = FakeClientDelegate()
        let client = TelnetClientSession(delegate: output, ipAddress: "::1")
        _ = client.processInput([255, 253, 39])
        output.writtenChunks.removeAll()
        _ = client.processInput(NewEnviron.packet(command: 1, entries: [.init(name: "IPADDRESS", userDefined: true)]))
        let initial = try #require(NewEnviron.decode(output.allWrittenBytes))
        #expect(initial.entries == [.init(name: "IPADDRESS", value: "::1", userDefined: true)])
        output.writtenChunks.removeAll()
        client.ipAddress = "::2"
        let updated = try #require(NewEnviron.decode(output.allWrittenBytes))
        #expect(updated.entries == [.init(name: "IPADDRESS", value: "::2", userDefined: true)])
    }

    @Test func zeroAndUndefinedReportsOverrideThenRestoreTTYPECapabilities() {
        let server = TelnetSession(restoring: [.utf8, .colors256], mttsFlags: [.utf8, .colors256],
            terminalType: "TTYPE-CLIENT", windowSize: (80, 24), proxy: "")
        _ = server.processInput([255, 251, 39])
        _ = server.processInput(NewEnviron.packet(command: 0, entries: [.init(name: "MTTS", value: "0")]))
        #expect(server.hasMTTS)
        #expect(server.mttsFlags.rawValue == 0)
        #expect(server.commFlags.contains(.utf8) == false)
        #expect(server.commFlags.contains(.colors256) == false)
        _ = server.processInput(NewEnviron.packet(command: 2, entries: [.init(name: "MTTS")]))
        #expect(server.commFlags.contains(.utf8))
        #expect(server.commFlags.contains(.colors256))
    }

    @Test(arguments: ["999.0.0.1", "192.0.2", "localhost", "1.2.3.4:80", "2001:::1", "1::2::3", "::ffff:999.1.1.1", "[::1]", "fe80::1%en0", "01.2.3.4"])
    func rejectsInvalidAddresses(address: String) {
        let server = TelnetSession()
        _ = server.processInput([255, 251, 39])
        _ = server.processInput(NewEnviron.packet(command: 0, entries: [.init(name: "IPADDRESS", value: "192.0.2.1")]))
        _ = server.processInput(NewEnviron.packet(command: 2, entries: [.init(name: "IPADDRESS", value: address)]))
        #expect(server.proxy == "192.0.2.1")
    }

    @Test func rejectsMalformedReportsWithoutConsumingFollowingText() {
        let server = TelnetSession()
        _ = server.processInput([255, 251, 39])
        let packet: [UInt8] = [255, 250, 39, 0, 1, 65, 255, 240]
        #expect(server.processInput(packet + Array("look\n".utf8)) == Array("look\n".utf8))
        #expect(server.environment == MNESEnvironment())
        for value in ["-1", "999999999999999999999999", "abc"] {
            _ = server.processInput(NewEnviron.packet(command: 0, entries: [.init(name: "MTTS", value: value)]))
            #expect(server.hasMTTS == false)
        }
        _ = server.processInput(NewEnviron.packet(command: 0, entries: [.init(name: "CLIENT_NAME", value: "bad\u{1B}[2J")]))
        #expect(server.environment.clientName == nil)
    }

    @Test func codecHandlesEscapesAndDoesNotConfuseEscapedIACWithTerminator() throws {
        let entry = NewEnviron.Entry(name: "EXAMPLE", value: "a\0b\u{1}c\u{2}d\u{3}")
        let packet = NewEnviron.packet(command: 0, entries: [entry])
        #expect(try #require(NewEnviron.decode(packet)).entries == [entry])
        let escaped: [UInt8] = [255, 250, 39, 0, 0, 65, 1, 255, 255, 240]
        #expect(NewEnviron.frameLength(escaped, at: 0) == nil)
        #expect(NewEnviron.frameLength(escaped + [255, 240], at: 0) == escaped.count + 2)
    }

    @Test(arguments: [[], [NewEnviron.Entry(name: "")]])
    func clientAnswersAllVariableRequests(entries: [NewEnviron.Entry]) throws {
        let output = FakeClientDelegate()
        let client = TelnetClientSession(delegate: output, clientVersion: "1", ipAddress: "::1")
        _ = client.processInput([255, 253, 39])
        output.writtenChunks.removeAll()
        _ = client.processInput(NewEnviron.packet(command: 1, entries: entries))
        let response = try #require(NewEnviron.decode(output.allWrittenBytes))
        #expect(response.command == 0)
        #expect(response.entries.map(\.name) == MNESEnvironment.variableNames)
    }

    @Test func clientOnlyUpdatesRequestedVariablesAndResetsSubscriptions() throws {
        let output = FakeClientDelegate()
        let client = TelnetClientSession(delegate: output)
        _ = client.processInput([255, 253, 39])
        _ = client.processInput(NewEnviron.packet(command: 1, entries: [.init(name: "IPADDRESS"), .init(name: "UNKNOWN")]))
        let packet = try #require(output.writtenChunks.last)
        let response = try #require(NewEnviron.decode(packet))
        #expect(response.entries == [.init(name: "IPADDRESS"), .init(name: "UNKNOWN")])
        output.writtenChunks.removeAll()
        client.clientVersion = "2"
        #expect(output.allWrittenBytes.isEmpty)
        client.ipAddress = "::1"
        #expect(try #require(NewEnviron.decode(output.allWrittenBytes)).command == 2)
        output.writtenChunks.removeAll()
        _ = client.processInput([255, 254, 39])
        #expect(output.allWrittenBytes == [255, 252, 39])
        output.writtenChunks.removeAll()
        client.ipAddress = "::2"
        _ = client.processInput([255, 253, 39])
        output.writtenChunks.removeAll()
        client.ipAddress = "::3"
        #expect(output.allWrittenBytes.isEmpty)
    }

    @Test func oversizedFragmentsAreDiscardedUntilTerminator() {
        let server = TelnetSession()
        _ = server.processInput([255, 251, 39])
        let oversized: [UInt8] = [255, 250, 39, 0, 0] + Array(repeating: 65, count: 9000) + [255]
        #expect(server.processInput(oversized).isEmpty)
        #expect(server.processInput([240] + Array("look\n".utf8)) == Array("look\n".utf8))
        #expect(server.environment == MNESEnvironment())
        let client = TelnetClientSession()
        #expect(client.processInput([255, 250, 39, 1, 0] + Array(repeating: 65, count: 9000)).isEmpty)
        #expect(client.processInput([255, 240] + Array("hello".utf8)) == Array("hello".utf8))
    }

    @Test func serverIgnoresUnnegotiatedDataAndDuplicateNegotiations() {
        let output = EnvironmentDelegate()
        let server = TelnetSession(delegate: output)
        let packet = NewEnviron.packet(command: 0, entries: [.init(name: "IPADDRESS", value: "::1")])
        _ = server.processInput(packet)
        #expect(server.proxy.isEmpty)
        _ = server.processInput([255, 251, 39])
        _ = server.processInput(packet)
        output.writtenChunks.removeAll()
        _ = server.processInput([255, 251, 39])
        #expect(output.allWrittenBytes.isEmpty)
        _ = server.processInput([255, 252, 39])
        #expect(server.environment == MNESEnvironment())
        #expect(server.newEnvironEnabled == false)
        #expect(output.changes.map(\.ipAddress) == ["::1", nil])
    }
}

private final class EnvironmentDelegate: TelnetSessionDelegate {
    var writtenChunks: [[UInt8]] = []
    var changes: [MNESEnvironment] = []
    var allWrittenBytes: [UInt8] { writtenChunks.flatMap { $0 } }
    func telnetSession(_ session: TelnetSession, write data: [UInt8]) { writtenChunks.append(data) }
    func telnetSession(_ session: TelnetSession, environmentChanged environment: MNESEnvironment) {
        changes.append(environment)
    }
}
