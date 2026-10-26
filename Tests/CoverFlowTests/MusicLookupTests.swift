import XCTest
@testable import CoverFlow

private final class LookupProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: result.1)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.2); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
final class MusicLookupTests: XCTestCase {
    private func client() -> MusicLookupClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LookupProtocol.self]
        return MusicLookupClient(session: URLSession(configuration: config))
    }
    func testLyricsPreferCorrectDurationAndKeepPlainLyricsAvailable() async throws {
        let records: [[String: Any]] = [
            ["id":1,"trackName":"Song","artistName":"Artist","albumName":"Live","duration":400,"instrumental":false,"syncedLyrics":"[00:01]Live"],
            ["id":2,"trackName":"Song","artistName":"Artist","albumName":"Album","duration":201,"instrumental":false,"syncedLyrics":"[00:01]Synced"],
            ["id":3,"trackName":"Song","artistName":"Artist","albumName":"Album","duration":200,"instrumental":false,"plainLyrics":"Plain lyrics"],
            ["id":4,"trackName":"Song","artistName":"Artist","albumName":"Album","duration":200,"instrumental":true,"plainLyrics":""]]
        LookupProtocol.handler = { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")!.contains("CoverFlow/"))
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "Song & Dance")
            return (200,[:],try JSONSerialization.data(withJSONObject: records))
        }
        let matches = try await client().lyrics(title: "Song & Dance", artist: "Artist", duration: 200)
        XCTAssertEqual(matches.map(\.id), [2,3,1])
        XCTAssertTrue(matches[0].isSynced)
        XCTAssertFalse(matches[1].isSynced)
        XCTAssertEqual(matches[1].text, "Plain lyrics")
    }
    func testArtworkSearchDecodesEditionAndEscapesLuceneQuery() async throws {
        let id = UUID()
        LookupProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            XCTAssertTrue(query.contains(#"\"Deluxe\""#))
            let object: [String: Any] = ["release-groups": [["id":id.uuidString,"title":"Album","first-release-date":"1997-08-21","artist-credit":[["artist":["name":"Artist"]]]]]]
            return (200,[:],try JSONSerialization.data(withJSONObject: object))
        }
        let result = try await client().artwork(title: "Album \"Deluxe\"", artist: "Artist")
        XCTAssertEqual(result.first?.id, id)
        XCTAssertEqual(result.first?.artist, "Artist")
        XCTAssertEqual(result.first?.year, "1997-08-21")
    }
    func testSearchCanOmitUnknownArtist() {
        let lyrics = URLComponents(url: MusicLookupClient.lyricsURL(title: "Song", artist: " "), resolvingAgainstBaseURL: false)!
        XCTAssertEqual(lyrics.queryItems?.map(\.name), ["track_name"])
        let artwork = URLComponents(url: MusicLookupClient.artworkURL(title: "Album", artist: " "), resolvingAgainstBaseURL: false)!
        XCTAssertFalse(artwork.queryItems!.first!.value!.contains("artist:"))
    }
    func testServiceFailuresAndOversizedPayloadsAreReported() async throws {
        LookupProtocol.handler = { _ in (429,["Retry-After":"17"],Data()) }
        do { _ = try await client().lyrics(title: "Song", artist: "Artist", duration: 1); XCTFail() }
        catch MusicLookupError.rateLimited(let seconds) { XCTAssertEqual(seconds,17) }
        LookupProtocol.handler = { _ in (200,["Content-Length":"99999999"],Data("[]".utf8)) }
        do { _ = try await client().lyrics(title: "Song", artist: "Artist", duration: 1); XCTFail() }
        catch MusicLookupError.tooLarge { }
        LookupProtocol.handler = { _ in (200,[:],Data("not json".utf8)) }
        do { _ = try await client().lyrics(title: "Song", artist: "Artist", duration: 1); XCTFail() }
        catch MusicLookupError.invalidResponse { }
    }
    func testDownloadedAndImportedPlainLyricsPersistWithoutReplacingAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID(), audio = folder.appendingPathComponent("song.mp3")
        try Data("original audio".utf8).write(to: audio)
        _ = try LyricsStore.importText("[00:01.20]A synced line", trackID: id, directory: folder)
        XCTAssertTrue(try LyricsStore.find(trackID: id, audioURL: audio, directory: folder)!.document.isSynced)
        let local = folder.appendingPathComponent("plain.lyrics")
        try Data("An untimed lyric\nAnother line".utf8).write(to: local)
        _ = try LyricsStore.importFile(local, trackID: id, directory: folder)
        let saved = try LyricsStore.find(trackID: id, audioURL: audio, directory: folder)!
        XCTAssertFalse(saved.document.isSynced)
        XCTAssertEqual(saved.document.plainText,"An untimed lyric\nAnother line")
        XCTAssertEqual(try Data(contentsOf: audio),Data("original audio".utf8))
        XCTAssertThrowsError(try LyricsStore.importText("", trackID: id, directory: folder))
        XCTAssertEqual(try LyricsStore.find(trackID: id, audioURL: audio, directory: folder)!.document,saved.document)
    }
}
