import Foundation

/// An error carrying the HTTP status and raw body, so callers can surface Bambuddy's JSON `detail`
/// (e.g. a drying 409's "AMS is busy") instead of a wall of transport noise.
struct BambuddyError: LocalizedError, Sendable {
    let method: String
    let path: String
    let status: Int
    let body: String

    /// Human message: the API's JSON `detail` when present, else the whole response body.
    var detail: String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let d = obj["detail"] as? String {
            return d
        }
        return body.isEmpty ? "HTTP \(status)" : body
    }

    var errorDescription: String? { detail }
    /// The raw form, matching the RN client's thrown message. Used by string-matching call sites.
    var rawMessage: String { "Bambuddy \(method) \(path) -> HTTP \(status) \(body)".trimmingCharacters(in: .whitespaces) }
}

enum ConnectErrorKind: Sendable {
    case timeout, auth, notFound, server, network, unknown
}

/// Classify a failure from `probe` into a user-facing onboarding message. The whole point is to
/// split the two failures that otherwise look identical — server-unreachable vs. key-rejected — so a
/// silent "Connecting" forever becomes an actionable error at the moment of entry.
func classifyConnectError(_ error: Error) -> (kind: ConnectErrorKind, message: String) {
    if let e = error as? BambuddyError {
        switch e.status {
        case 401, 403:
            return (.auth, "Server reached, but the API key was rejected (HTTP \(e.status)). Double-check the key.")
        case 404:
            return (.notFound, "Reached that host, but it doesn't respond like a Bambuddy server (HTTP 404). Check the URL.")
        case 500...:
            return (.server, "The Bambuddy server returned an error (HTTP \(e.status)). It may be down or restarting.")
        default:
            return (.unknown, "Unexpected response from the server (HTTP \(e.status)).")
        }
    }
    let ns = error as NSError
    guard ns.domain == NSURLErrorDomain else { return (.unknown, error.localizedDescription) }
    switch ns.code {
    case NSURLErrorTimedOut:
        return (.timeout, "Timed out reaching the server. Check the URL, and that your phone can actually reach that host (same Wi‑Fi / VPN).")
    case NSURLErrorCancelled:
        return (.timeout, "Timed out reaching the server. Check the URL, and that your phone can actually reach that host (same Wi‑Fi / VPN).")
    default:
        return (.network, "Can't reach that URL. Check the scheme (https), host/port, your network, and that the server's TLS certificate is trusted by the phone.")
    }
}

/// Caches the admin JWT. Isolated so the token can be read/refreshed from concurrent requests.
private actor AdminTokenStore {
    // JWTs live 24h with no refresh — re-login proactively at 23h so a long-running app doesn't hit
    // mid-action expiry as the norm (the 401-retry still covers server-side invalidation).
    private static let maxAge: TimeInterval = 23 * 60 * 60
    private var token: String?
    private var mintedAt: Date?

    func cached() -> String? {
        guard let token, let mintedAt, Date().timeIntervalSince(mintedAt) <= Self.maxAge else { return nil }
        return token
    }

    func store(_ t: String) {
        token = t
        mintedAt = Date()
    }
}

/// Thin typed wrapper over the Bambuddy endpoints the app uses. No UI.
///
/// Port of `src/api/bambuddyClient.ts`. Two auth mechanisms coexist and must not be mixed up:
/// - `X-API-Key` header — everything normal.
/// - `?token=` camera **stream** token — thumbnails, snapshots and the MJPEG stream ONLY. These
///   reject the API key with a 401.
final class BambuddyClient: Sendable {
    let baseUrl: String
    private let apiKey: String
    private let extraHeaders: [String: String]
    private let adminUsername: String?
    private let adminPassword: String?
    private let session: URLSession
    private let tokens = AdminTokenStore()

    init(
        baseUrl: String,
        apiKey: String,
        extraHeaders: [String: String] = [:],
        adminUsername: String? = nil,
        adminPassword: String? = nil,
        session: URLSession = .shared
    ) {
        // Trim trailing slashes so path concatenation never doubles them.
        var b = baseUrl
        while b.hasSuffix("/") { b.removeLast() }
        self.baseUrl = b
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        let u = adminUsername?.trimmingCharacters(in: .whitespaces)
        self.adminUsername = (u?.isEmpty == false) ? u : nil
        self.adminPassword = (adminPassword?.isEmpty == false) ? adminPassword : nil
        self.session = session
    }

    /// Whether admin credentials are configured (drives Settings UI + error wording).
    var hasAdminLogin: Bool { adminUsername != nil && adminPassword != nil }

    /// ws(s):// origin derived from baseUrl, for the realtime store.
    var wsBaseUrl: String {
        if baseUrl.hasPrefix("https") { return "wss" + baseUrl.dropFirst(5) }
        if baseUrl.hasPrefix("http") { return "ws" + baseUrl.dropFirst(4) }
        return baseUrl
    }

    /// Auth headers for endpoints fetched OUTSIDE `req` (image loaders, download tasks). These
    /// SD-card endpoints use X-API-Key (verified live), NOT the camera `?token=`.
    func authHeaders() -> [String: String] {
        var h = extraHeaders
        h["X-API-Key"] = apiKey
        return h
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    // MARK: - Transport

    /// Build an absolute URL from the configured base.
    ///
    /// `URL(string:)` still returns nil for things a person can genuinely paste — a stray `]`, `<`/`>`,
    /// a bare `%` in the authority — and nothing upstream validates the base URL into a parseable
    /// form (`ConfigRules.sanitizeBaseUrl` only trims). Force-unwrapping here killed the app at the
    /// Connect button instead of letting `classifyConnectError` say what was wrong, so this throws a
    /// user-facing message: `SproutError` is a `LocalizedError`, and the classifier falls through to
    /// `localizedDescription` for anything that isn't an HTTP or URLError failure.
    private func makeURL(_ path: String) throws -> URL {
        guard let url = URL(string: baseUrl + path) else {
            throw SproutError("That server URL isn't valid. Check the scheme (https), host and port — it can't contain spaces or stray brackets.")
        }
        return url
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil, timeout: TimeInterval = 60) throws -> URLRequest {
        var r = URLRequest(url: try makeURL(path))
        r.httpMethod = method
        r.httpBody = body
        r.timeoutInterval = timeout
        for (k, v) in authHeaders() { r.setValue(v, forHTTPHeaderField: k) }
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return r
    }

    @discardableResult
    private func send(_ req: URLRequest, path: String) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            throw BambuddyError(
                method: req.httpMethod ?? "GET",
                path: path,
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, as: T.Type = T.self, timeout: TimeInterval = 60) async throws -> T {
        let data = try await send(request(path, timeout: timeout), path: path)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, json: (any Encodable)? = nil, as: T.Type = T.self) async throws -> T {
        var body: Data?
        if let json { body = try Self.encoder.encode(AnyEncodable(json)) }
        let data = try await send(request(path, method: "POST", body: body, contentType: json != nil ? "application/json" : nil), path: path)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func postVoid(_ path: String, json: (any Encodable)? = nil) async throws {
        var body: Data?
        if let json { body = try Self.encoder.encode(AnyEncodable(json)) }
        try await send(request(path, method: "POST", body: body, contentType: json != nil ? "application/json" : nil), path: path)
    }

    // MARK: - Admin (JWT) transport

    /// Mint (and cache) an admin JWT. Throws a human message on bad credentials / 2FA accounts.
    @discardableResult
    private func adminLogin() async throws -> String {
        struct Login: Encodable { let username: String; let password: String }
        var r = URLRequest(url: try makeURL("/api/v1/auth/login"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONEncoder().encode(Login(username: adminUsername ?? "", password: adminPassword ?? ""))
        let (data, response) = try await session.data(for: r)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if obj["requires_2fa"] as? Bool == true {
            throw SproutError("Admin login failed: this account has 2FA enabled, which the app can’t complete. Use a non-2FA admin account.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let token = obj["access_token"] as? String else {
            throw SproutError("Admin login failed (HTTP \(status)) — check the admin username/password in Settings.")
        }
        await tokens.store(token)
        return token
    }

    /// Settings pre-flight: verify the configured admin credentials actually log in.
    func verifyAdminLogin() async throws { _ = try await adminLogin() }

    /// Request against an ADMIN-gated endpoint. With admin credentials configured this authenticates
    /// via Bearer JWT (cached; re-login on age-out, one retry on 401/403 for server-side
    /// invalidation). Without them it falls through to the API key so the server stays the source of
    /// truth — but the categorical "API keys cannot be used for administrative operations" 403 is
    /// rewritten into an actionable message pointing at Settings.
    @discardableResult
    private func adminSend(_ path: String, method: String = "GET", json: (any Encodable)? = nil) async throws -> Data {
        var body: Data?
        if let json { body = try Self.encoder.encode(AnyEncodable(json)) }

        guard hasAdminLogin else {
            do {
                return try await send(request(path, method: method, body: body, contentType: json != nil ? "application/json" : nil), path: path)
            } catch let e as BambuddyError where e.body.contains("administrative operations") {
                throw SproutError("This action needs the Bambuddy admin login. Add the admin username + password in Settings → Edit, then retry.")
            }
        }

        var token: String
        if let cached = await tokens.cached() {
            token = cached
        } else {
            token = try await adminLogin()
        }

        func attempt(_ tok: String) async throws -> (Data, HTTPURLResponse?) {
            var r = URLRequest(url: try makeURL(path))
            r.httpMethod = method
            r.httpBody = body
            r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            for (k, v) in extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
            if json != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (d, resp) = try await session.data(for: r)
            return (d, resp as? HTTPURLResponse)
        }

        var (data, http) = try await attempt(token)
        if http?.statusCode == 401 || http?.statusCode == 403 {
            token = try await adminLogin()  // invalidated server-side (restart, password change) — once
            (data, http) = try await attempt(token)
        }
        guard let code = http?.statusCode, (200..<300).contains(code) else {
            throw BambuddyError(method: method, path: path, status: http?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: - Printers & status

    /// All registered printers (A1, H2C, …).
    func listPrinters() async throws -> [Printer] { try await get("/api/v1/printers/") }

    /// Onboarding pre-flight: confirm baseUrl + apiKey actually reach a Bambuddy server, returning
    /// its printer fleet so the caller can auto-select a real printer instead of guessing an id.
    /// Times out so a wrong/dead host fails fast instead of hanging the Connect button.
    func probe(timeout: TimeInterval = 8) async throws -> [Printer] {
        try await get("/api/v1/printers/", as: [Printer].self, timeout: timeout)
    }

    func getStatus(_ printerId: Int) async throws -> PrinterStatus {
        try await get("/api/v1/printers/\(printerId)/status")
    }

    /// Clear the printer's HMS notices (e.g. the benign mid-print ones the H2C emits).
    func clearHms(_ printerId: Int) async throws {
        try await postVoid("/api/v1/printers/\(printerId)/hms/clear")
    }

    /// Acknowledge the plate is clear, so the scheduler may dispatch the next job.
    ///
    /// This is NOT `queueResume` — that clears the previous-FAILURE gate and restores skipped items,
    /// which is a different thing entirely and left `awaiting_plate_clear` set. Sends no MQTT, so it
    /// works without LAN Developer Mode.
    func clearPlate(_ printerId: Int) async throws {
        try await postVoid("/api/v1/printers/\(printerId)/clear-plate")
    }

    /// Clear the previous-failure gate and restore skipped queue items. Distinct from `clearPlate`.
    func queueResume(_ printerId: Int) async throws {
        try await postVoid("/api/v1/queue/printer/\(printerId)/resume")
    }

    func setLight(_ printerId: Int, on: Bool) async throws {
        try await postVoid("/api/v1/printers/\(printerId)/chamber-light?on=\(on)")
    }

    func pause(_ printerId: Int) async throws { try await postVoid("/api/v1/printers/\(printerId)/print/pause") }
    func resume(_ printerId: Int) async throws { try await postVoid("/api/v1/printers/\(printerId)/print/resume") }
    func stop(_ printerId: Int) async throws { try await postVoid("/api/v1/printers/\(printerId)/print/stop") }

    func setSpeed(_ printerId: Int, mode: SpeedMode) async throws {
        try await postVoid("/api/v1/printers/\(printerId)/print-speed?mode=\(mode.rawValue)")
    }

    /// Start AMS filament drying.
    ///
    /// NOTE: duration is HOURS (Bambuddy validates 1-24 — minutes would 400); temp is 45-85 °C
    /// server-side but the AMS 2 Pro's hardware max is 65 °C (85 = AMS-HT only) — clamp via
    /// `DryerVM.maxTemp` before calling. `rotate` spins the spool for even drying. A blocked start
    /// returns 409 with a human reason — surface it via `BambuddyError.detail`.
    func dryingStart(_ printerId: Int, amsId: Int, temp: Int, hours: Int, filament: String? = nil, rotate: Bool? = nil) async throws {
        var q = [URLQueryItem(name: "ams_id", value: String(amsId)),
                 URLQueryItem(name: "temp", value: String(temp)),
                 URLQueryItem(name: "duration", value: String(hours))]
        if let filament { q.append(URLQueryItem(name: "filament", value: filament)) }
        if let rotate { q.append(URLQueryItem(name: "rotate_tray", value: String(rotate))) }
        var comps = URLComponents()
        comps.queryItems = q
        try await postVoid("/api/v1/printers/\(printerId)/drying/start?\(comps.percentEncodedQuery ?? "")")
    }

    func dryingStop(_ printerId: Int, amsId: Int) async throws {
        try await postVoid("/api/v1/printers/\(printerId)/drying/stop?ams_id=\(amsId)")
    }

    /// Server config incl. electricity price (`energyCostPerKwh`) + currency. Read works with the
    /// API key; writes are admin-JWT only.
    func getSettings() async throws -> AppSettings { try await get("/api/v1/settings/") }

    // MARK: - Tokens & camera URLs

    func mintWsToken() async throws -> String {
        struct R: Decodable { let token: String }
        return try await post("/api/v1/auth/ws-token", as: R.self).token
    }

    func mintCameraToken() async throws -> String {
        struct R: Decodable { let token: String }
        return try await post("/api/v1/printers/camera/stream-token", as: R.self).token
    }

    func snapshotUrl(_ printerId: Int, token: String) -> URL? {
        URL(string: "\(baseUrl)/api/v1/printers/\(printerId)/camera/snapshot?token=\(esc(token))")
    }

    /// MJPEG multipart live stream (`multipart/x-mixed-replace`).
    /// Token MUST be in the query; the X-API-Key header is rejected (401) on stream/snapshot.
    func streamUrl(_ printerId: Int, token: String, fps: Int = 10) -> URL? {
        URL(string: "\(baseUrl)/api/v1/printers/\(printerId)/camera/stream?token=\(esc(token))&fps=\(fps)")
    }

    /// Read-only staged camera diagnostics — explains *why* the stream is unavailable (e.g. a
    /// port-6000 timeout).
    func diagnoseCamera(_ printerId: Int) async throws -> CameraDiagnosis {
        try await post("/api/v1/printers/\(printerId)/camera/diagnose")
    }

    // MARK: - Library

    func listFiles() async throws -> [LibraryFile] { try await get("/api/v1/library/files") }
    func getFileDetail(_ fileId: Int) async throws -> LibraryFile { try await get("/api/v1/library/files/\(fileId)") }
    func getPlates(_ fileId: Int) async throws -> PlatesResponse { try await get("/api/v1/library/files/\(fileId)/plates") }
    func getGcode(_ fileId: Int) async throws -> String {
        let data = try await send(request("/api/v1/library/files/\(fileId)/gcode"), path: "gcode")
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Delete a library file. Needs the Manage-Library scope (works on Bambuddy ≥ 0.2.4.8).
    func deleteFile(_ fileId: Int) async throws {
        try await send(request("/api/v1/library/files/\(fileId)", method: "DELETE"), path: "/api/v1/library/files/\(fileId)")
    }

    /// Library thumbnails are gated by a camera *stream* token (`?token=`), NOT X-API-Key — the same
    /// token type as `snapshotUrl`. Returns nil when there's no token or no server-side thumbnail.
    func fileThumbUrl(_ fileId: Int, token: String?, thumbnailPath: String??) -> URL? {
        guard let token else { return nil }
        // An explicitly-null thumbnail_path means the server has no thumbnail; a missing key means
        // "unknown", which is still worth attempting.
        if case .some(.none) = thumbnailPath { return nil }
        return URL(string: "\(baseUrl)/api/v1/library/files/\(fileId)/thumbnail?token=\(esc(token))")
    }

    /// Rendered plate thumbnail (1-based index). Gated by the camera stream token.
    func plateThumbUrl(_ fileId: Int, plateIndex: Int, token: String?) -> URL? {
        guard let token else { return nil }
        return URL(string: "\(baseUrl)/api/v1/library/files/\(fileId)/plate-thumbnail/\(plateIndex)?token=\(esc(token))")
    }

    /// Tokenized library-file download URL (the slicer-token path — token IS the auth, so the URL
    /// works with no headers). Single-use, short-lived; mint per view.
    func mintFileDownloadUrl(_ fileId: Int, filename: String? = nil) async throws -> URL {
        let data = try await send(request("/api/v1/library/files/\(fileId)/slicer-token", method: "POST"), path: "slicer-token")
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let token = (obj["token"] ?? obj["slicer_token"] ?? obj["download_token"] ?? obj["value"]) as? String
        guard let token else { throw SproutError("slicer-token response had no recognizable token field") }
        let name = filename ?? "model-\(fileId).stl"
        guard let url = URL(string: "\(baseUrl)/api/v1/library/files/\(fileId)/dl/\(esc(token))/\(esc(name))") else {
            throw SproutError("could not build a download URL")
        }
        return url
    }

    /// Same-origin PATH of a library file's G-code, for the layer viewer's in-page fetch.
    func gcodePath(_ fileId: Int) -> String { "/api/v1/library/files/\(fileId)/gcode" }

    // MARK: - Printer onboard storage (SD card)

    func listPrinterFiles(_ printerId: Int, path: String = "/") async throws -> PrinterFileList {
        try await get("/api/v1/printers/\(printerId)/files?path=\(esc(path))")
    }

    func printerFileDownloadUrl(_ printerId: Int, path: String) -> URL? {
        URL(string: "\(baseUrl)/api/v1/printers/\(printerId)/files/download?path=\(esc(path))")
    }

    func printerPlateThumbUrl(_ printerId: Int, path: String, plateIndex: Int = 1) -> URL? {
        URL(string: "\(baseUrl)/api/v1/printers/\(printerId)/files/plate-thumbnail/\(plateIndex)?path=\(esc(path))")
    }

    func getPrinterFilePlates(_ printerId: Int, path: String) async throws -> PrinterFilePlates {
        try await get("/api/v1/printers/\(printerId)/files/plates?path=\(esc(path))")
    }

    func deletePrinterFile(_ printerId: Int, path: String) async throws {
        let p = "/api/v1/printers/\(printerId)/files?path=\(esc(path))"
        try await send(request(p, method: "DELETE"), path: p)
    }

    func getPrinterFileGcode(_ printerId: Int, path: String) async throws -> String {
        let p = "/api/v1/printers/\(printerId)/files/gcode?path=\(esc(path))"
        let data = try await send(request(p), path: p)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func printerGcodePath(_ printerId: Int, path: String) -> String {
        "/api/v1/printers/\(printerId)/files/gcode?path=\(esc(path))"
    }

    // MARK: - Slicing

    func getPresets() async throws -> Data {
        try await send(request("/api/v1/slicer/presets"), path: "/api/v1/slicer/presets")
    }

    struct LocalPresets: Decodable, Sendable {
        struct Row: Decodable, Sendable { let id: Int; let name: String }
        var process: [Row]?
        var filament: [Row]?
        var printer: [Row]?
    }

    func listLocalPresets() async throws -> LocalPresets { try await get("/api/v1/local-presets/") }

    /// Upsert the app's reusable override preset (ADMIN-gated — preset writes 403 on scoped keys).
    /// `setting` is a delta JSON with `inherits`; Bambuddy resolves the base at slice time. One row
    /// per name, updated in place so rows don't accumulate per slice. Returns the row id to
    /// reference as `{source:"local", id}` in `slice`.
    func upsertLocalPreset(name: String, presetType: String, setting: [String: JSONValue]) async throws -> Int {
        let presets = try await listLocalPresets()
        let rows = presetType == "process" ? presets.process : presets.filament
        if let row = rows?.first(where: { $0.name == name }) {
            struct Body: Encodable { let setting: [String: JSONValue] }
            _ = try await adminSend("/api/v1/local-presets/\(row.id)", method: "PUT", json: Body(setting: setting))
            return row.id
        }
        struct Create: Encodable { let name: String; let presetType: String; let setting: [String: JSONValue] }
        let data = try await adminSend("/api/v1/local-presets/", method: "POST", json: Create(name: name, presetType: presetType, setting: setting))
        struct Created: Decodable { let id: Int? }
        guard let id = (try? Self.decoder.decode(Created.self, from: data))?.id else {
            throw SproutError("local-preset create returned no id")
        }
        return id
    }

    func slice(_ fileId: Int, body: [String: JSONValue]) async throws -> Int {
        struct R: Decodable { let jobId: Int }
        return try await post("/api/v1/library/files/\(fileId)/slice", json: body, as: R.self).jobId
    }

    func getSliceJob(_ jobId: Int) async throws -> SliceJob { try await get("/api/v1/slice-jobs/\(jobId)") }

    // MARK: - Queue

    func listQueue() async throws -> [QueueItem] { try await get("/api/v1/queue/") }

    @discardableResult
    func enqueue(_ body: [String: JSONValue]) async throws -> Data {
        try await send(request("/api/v1/queue/", method: "POST", body: try Self.encoder.encode(body), contentType: "application/json"), path: "/api/v1/queue/")
    }

    func queueAction(_ itemId: Int, action: String) async throws {
        try await postVoid("/api/v1/queue/\(itemId)/\(action)")
    }

    /// Re-print a finished job by queueing it again.
    ///
    /// `POST /archives/{id}/reprint` is GONE — Bambuddy answers 410 with "Direct archive reprint has
    /// been removed. Create a print queue item with POST /queue/." The queue accepts an `archive_id`
    /// directly, so no library-file lookup is needed (archives do not expose one anyway).
    func reprint(archiveId: Int, printerId: Int) async throws {
        try await enqueue(["printer_id": .int(printerId), "archive_id": .int(archiveId), "use_ams": .bool(true)])
    }

    // MARK: - AMS

    func amsLoad(_ printerId: Int, trayId: Int) async throws {
        try await postVoid("/api/v1/printers/\(printerId)/ams/load?tray_id=\(trayId)")
    }

    func amsUnload(_ printerId: Int) async throws {
        try await postVoid("/api/v1/printers/\(printerId)/ams/unload")
    }

    // MARK: - Inventory

    func listSpools() async throws -> [Spool] { try await get("/api/v1/inventory/spools") }

    /// AMS slot -> spool assignments; each item embeds the full `spool`. Returns [] on failure so
    /// the AMS view falls back to status-only tray data.
    func listAssignments(printerId: Int? = nil) async -> [SlotAssignment] {
        let q = printerId.map { "?printer_id=\($0)" } ?? ""
        return (try? await get("/api/v1/inventory/assignments\(q)", as: [SlotAssignment].self)) ?? []
    }

    // MARK: - Print history

    func getPrintLog(limit: Int = 50) async throws -> PrintLogPage {
        try await get("/api/v1/print-log/?limit=\(limit)")
    }

    func getArchiveStats() async throws -> ArchiveStats { try await get("/api/v1/archives/stats") }

    /// Print-log thumbnails are gated by the camera *stream* token — identical to `fileThumbUrl`.
    func printLogThumbUrl(_ entryId: Int, token: String?, thumbnailPath: String??) -> URL? {
        guard let token else { return nil }
        if case .some(.none) = thumbnailPath { return nil }
        return URL(string: "\(baseUrl)/api/v1/print-log/\(entryId)/thumbnail?token=\(esc(token))")
    }

    // MARK: - Sensor history

    /// Per-minute history for one sensor. `hours` is capped at 168 server-side.
    /// Used for the plate-cooldown curve and for reading room temperature off the idle floor.
    func sensorHistory(_ printerId: Int, kind: String, hours: Int) async -> SensorHistory? {
        try? await get("/api/v1/printer-sensor-history/\(printerId)?hours=\(hours)&kinds=\(kind)", as: SensorHistory.self)
    }

    // MARK: - Smart plugs

    /// The printer's own plug. NOTE: by-printer returns a SINGLE plug, so only one plug may be bound
    /// to a printer — bind anything else (AMS, peripherals) to no printer and reach it via `listPlugs`.
    func getPlug(_ printerId: Int) async -> SmartPlug? {
        try? await get("/api/v1/smart-plugs/by-printer/\(printerId)", as: SmartPlug.self)
    }

    /// Every plug Bambuddy knows about, printer-bound or not.
    func listPlugs() async -> [SmartPlug] {
        // The endpoint has returned both a bare array and a {items:[…]} envelope across versions.
        if let arr = try? await get("/api/v1/smart-plugs/", as: [SmartPlug].self) { return arr }
        struct Env: Decodable { let items: [SmartPlug]? }
        return (try? await get("/api/v1/smart-plugs/", as: Env.self))?.items ?? []
    }

    func plugStatus(_ plugId: Int) async throws -> PlugStatus { try await get("/api/v1/smart-plugs/\(plugId)/status") }

    func plugControl(_ plugId: Int, on: Bool) async throws {
        try await postVoid("/api/v1/smart-plugs/\(plugId)/control", json: ["action": JSONValue.string(on ? "on" : "off")])
    }

    // MARK: - Maintenance

    func getMaintenance(_ printerId: Int) async throws -> MaintenancePrinter {
        try await get("/api/v1/maintenance/printers/\(printerId)")
    }

    func getMaintenanceSummary() async throws -> MaintenanceSummary { try await get("/api/v1/maintenance/summary") }

    /// MUTATES — resets an item's counter ("mark done"). Body is REQUIRED (a bodyless POST 422s).
    /// ADMIN-gated: Bambuddy refuses API keys here regardless of permissions (verified live: key →
    /// 403, JWT → past auth), so this routes through the admin transport.
    func performMaintenance(_ itemId: Int, notes: String? = nil) async throws {
        struct Body: Encodable { let notes: String? }
        _ = try await adminSend("/api/v1/maintenance/items/\(itemId)/perform", method: "POST", json: Body(notes: notes))
    }

    // MARK: - MakerWorld

    func makerWorldStatus() async throws -> MakerWorldStatus { try await get("/api/v1/makerworld/status") }

    /// Resolve a MakerWorld model URL → design + printable profiles. No cloud token needed.
    /// Throws on 400 (not a MW url) / 404 (model not found).
    func resolveMakerWorld(_ url: String) async throws -> MakerWorldResolved {
        try await post("/api/v1/makerworld/resolve", json: ["url": JSONValue.string(url)])
    }

    /// MUTATING — downloads the 3MF into the library. Requires `status.canDownload == true`.
    func importMakerWorld(_ body: MakerWorldImportRequest) async throws -> MakerWorldImportResponse {
        try await post("/api/v1/makerworld/import", json: body)
    }

    /// MakerWorld CDN thumbnail via the server proxy (unauthenticated — URL is sufficient).
    func makerworldThumbUrl(_ cdnUrl: String?) -> URL? {
        guard let cdnUrl, !cdnUrl.isEmpty else { return nil }
        return URL(string: "\(baseUrl)/api/v1/makerworld/thumbnail?url=\(esc(cdnUrl))")
    }

    // MARK: - Upload

    /// Upload a local file to the library.
    ///
    /// The body is assembled into a temp file and sent with `uploadTask(fromFile:)` rather than held
    /// in memory — a sliced 3MF can be tens of megabytes, and the RN build hit exactly this wall
    /// (Expo's WinterCG fetch rejected RN's `{uri,name,type}` FormData parts, forcing a native
    /// upload). Progress is reported from the session delegate.
    func uploadFile(_ fileURL: URL, name: String, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> Int {
        let boundary = "Boundary-\(UUID().uuidString)"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).tmp")

        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
        }

        var head = "--\(boundary)\r\n"
        head += "Content-Disposition: form-data; name=\"file\"; filename=\"\(Self.escapeFormDataFilename(name))\"\r\n"
        head += "Content-Type: application/octet-stream\r\n\r\n"
        try handle.write(contentsOf: Data(head.utf8))

        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try handle.close()

        var req = URLRequest(url: try makeURL("/api/v1/library/files"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 3600

        let (data, response) = try await UploadDelegate.perform(request: req, fromFile: tmp, onProgress: onProgress)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw BambuddyError(method: "POST", path: "/api/v1/library/files", status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        struct R: Decodable { let id: Int }
        return try Self.decoder.decode(R.self, from: data).id
    }

    private func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? s
    }

    /// Escape a filename for a multipart `Content-Disposition` header.
    ///
    /// The name is the user's own — `staged.lastPathComponent` straight from the document picker —
    /// and `"`, CR and LF are all legal in an APFS filename. Interpolated raw, a quote closes the
    /// quoted-string early (the file lands in the library under a truncated name) and a CRLF injects
    /// further MIME headers into the part.
    ///
    /// This is the WHATWG form-data escape — `"` → `%22`, CR → `%0D`, LF → `%0A` — deliberately
    /// rather than backslash quoted-pairs: it is byte-for-byte what browsers emit, so it is the input
    /// every server-side multipart parser is actually exercised against.
    static func escapeFormDataFilename(_ name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\"", with: "%22")
        // An empty filename makes the part nameless, which FastAPI rejects as a malformed upload.
        return escaped.isEmpty ? "upload.bin" : escaped
    }
}

/// A plain message error for app-level failures that aren't HTTP responses.
struct SproutError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?/#")
        return set
    }()
}

/// Type-erasing shim so `post(json:)` can take any Encodable.
private struct AnyEncodable: Encodable {
    private let wrapped: any Encodable
    init(_ wrapped: any Encodable) { self.wrapped = wrapped }
    func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
}

/// A dynamic JSON value, for the slice/queue request bodies whose shape is server-defined.
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
