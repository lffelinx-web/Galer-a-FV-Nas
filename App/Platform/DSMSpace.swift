import Foundation

/// Reads the free space of the share from the Synology DSM API (File Station), because
/// DSM does not report it over WebDAV. It signs in with the same account, asks for the
/// shares with their volume status and signs out again. Accounts with two-step
/// verification cannot sign in this way; then no space is shown.
enum DSMSpace {
    private struct Response<T: Decodable>: Decodable {
        let success: Bool
        let data: T?
    }
    private struct Login: Decodable { let sid: String }
    private struct Shares: Decodable { let shares: [Share] }
    struct Share: Decodable {
        let name: String
        let path: String?
        let additional: Additional?
        struct Additional: Decodable { let volume_status: Volume? }
        struct Volume: Decodable {
            let freespace: Int64?
            let totalspace: Int64?
        }
    }

    static func read(_ account: NASAccount, transport: NASTransport) async throws -> NASSpace? {
        guard let base = entryURL(account) else { return nil }
        let form = "api=SYNO.API.Auth&version=6&method=login&session=FileStation&format=sid&account=\(encode(account.username))&passwd=\(encode(account.password))"
        let login = try await transport.request(base, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(form.utf8), limit: 100_000)
        guard let sid = (try? JSONDecoder().decode(Response<Login>.self, from: login.data))?.data?.sid else { return nil }
        defer {
            if let logout = URL(string: base.absoluteString + "?api=SYNO.API.Auth&version=6&method=logout&session=FileStation&_sid=\(encode(sid))") {
                Task { _ = try? await transport.request(logout, limit: 10_000) }
            }
        }
        guard let url = URL(string: base.absoluteString + "?api=SYNO.FileStation.List&version=2&method=list_share&additional=%5B%22volume_status%22%5D&_sid=\(encode(sid))") else { return nil }
        let response = try await transport.request(url, limit: 500_000)
        guard let shares = (try? JSONDecoder().decode(Response<Shares>.self, from: response.data))?.data?.shares else { return nil }
        return space(for: account.root, in: shares)
    }

    static func entryURL(_ account: NASAccount) -> URL? {
        guard let host = account.root.host else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = account.dsmPortValue
        components.path = "/webapi/entry.cgi"
        return components.url
    }

    /// The share that holds the WebDAV folder: `/home/Photos` lives in the `home` share.
    static func space(for root: URL, in shares: [Share]) -> NASSpace? {
        let first = root.pathComponents.dropFirst().first?.lowercased() ?? ""
        let share = shares.first { $0.name.lowercased() == first || $0.path?.lowercased() == "/" + first } ?? shares.first
        guard let volume = share?.additional?.volume_status, let free = volume.freespace, let total = volume.totalspace, total > 0 else { return nil }
        return NASSpace(used: max(0, total - free), available: free)
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
