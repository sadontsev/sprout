import Foundation

// MARK: - Access

/// What a MakerWorld import is blocked on, if anything.
///
/// `GET /makerworld/status` answers with ONE boolean, `can_download`, derived from a chain of three
/// independent conditions whose remedies are three different pages. Collapsing them is why the panel
/// used to tell the owner to sign in to Bambu Cloud while the server was *already* signed in and the
/// real gap was a missing scope on the API key — the remedy would have changed nothing.
///
/// This is the codebase's recurring bug in its usual disguise (CLAUDE.md): a predicate that answers a
/// NEARBY question. "The server holds a cloud token" and "this API key may read the cloud account"
/// sound like synonyms and are not. So they are asked separately and named for their own questions.
///
/// A fourth condition — *will THIS model download?* — is deliberately absent, because it is
/// unknowable before the attempt: paid, points-redeemable, region-locked and early-access models all
/// resolve fine and refuse at import. `MakerWorldAvailability` carries the hints; the `403` body is
/// the answer.
enum MakerWorldAccess: Equatable, Sendable {
    /// Still asking. The import button waits rather than guessing.
    case checking
    /// A token exists and this key can use it.
    case ready
    /// `GET /cloud/status` → 403: the key has no `can_access_cloud` scope, so the server reports "no
    /// token" while a perfectly good one sits on the user row.
    case keyLacksCloudScope
    /// The key can read the cloud account, and there is no usable token on it.
    case serverNotSignedIn
    /// Neither question could be asked — offline, or Bambuddy is down.
    case unreachable

    /// Whether importing is possible. Everything else on the panel — resolve, preview, the profile
    /// list — works regardless, because resolving is anonymous.
    var blocksImport: Bool { self != .ready }

    /// The remedy, named for the condition it actually fixes. `nil` when there is nothing to say.
    var message: String? {
        switch self {
        case .checking, .ready:
            return nil
        case .keyLacksCloudScope:
            return "This app’s API key can’t read your Bambu Cloud login, so it can’t download files. "
                + "Enable “Allow cloud access” on the key in Bambuddy → Settings → API Keys."
        case .serverNotSignedIn:
            return "Your Bambuddy server isn’t signed in to Bambu Cloud. Sign in under Bambuddy → "
                + "Profiles → Cloud Profiles. Bambuddy treats a sign-in as valid for 30 days."
        case .unreachable:
            return "Couldn’t check your Bambu Cloud connection. Resolving a link will try again."
        }
    }

    /// Whether this state can clear itself without the user going anywhere.
    ///
    /// `.unreachable` is a snapshot of one instant — the server may already be back — so anything that
    /// proves the server is reachable should re-ask rather than leave the button locked for the life
    /// of the panel. The other two name a remedy that has to be applied elsewhere, so re-probing them
    /// on the spot would achieve nothing.
    var worthRetrying: Bool { self == .unreachable }
}

/// The outcome of `GET /cloud/status`, reduced to the only three shapes that change the answer.
enum MakerWorldCloudProbe: Equatable, Sendable {
    /// `403` — the key is not scoped for cloud access.
    case forbidden
    /// `200` — with the server's own view of whether a token is present and unexpired.
    case readable(authenticated: Bool)
    /// The request itself failed.
    case failed
}

// MARK: - Profiles

/// One filament slot a profile asks for.
struct MWSlot: Hashable, Sendable {
    var type: String?
    var color: String?
    var grams: Double?

    init(type: String? = nil, color: String? = nil, grams: Double? = nil) {
        self.type = type
        self.color = color
        self.grams = grams
    }
}

/// What MakerWorld publishes about a profile, when it publishes anything.
///
/// Its absence is the common case, not the edge case — see `MWProfileRow.detail`.
struct MWProfileDetail: Hashable, Sendable {
    var seconds: Double?
    var grams: Double?
    var needAms: Bool = false
    var slots: [MWSlot] = []
    var materialCount: Int?
    var colorCount: Int?
    var plateCount: Int = 1
    /// From `projectSettings.layerHeight`, e.g. `"0.25"`. Seeds the wizard's quality step.
    var layerHeight: String?
    /// `compatibility.devProductName` — the machine this profile was sliced for.
    var slicedFor: String?
    /// `otherCompatibility[].devProductName` — every other machine MakerWorld marks it applicable to.
    var alsoMarkedFor: [String] = []

    /// How many filaments a print of this profile needs. This is the number the wizard has to be able
    /// to map; anything above 1 is a capability question, not a display detail.
    var slotCount: Int { max(slots.count, 1) }

    /// Whether MakerWorld marks this profile as applicable to `product` (e.g. `"H2C"`).
    ///
    /// **Not a printability claim.** It says MakerWorld considers the profile's *slicing settings*
    /// suitable for that machine — 36 of 37 profiles on a popular model carry it, so as a positive
    /// badge it is decoration. Only its absence carries information, and even that is a note rather
    /// than a block: every import is re-sliced for this printer anyway.
    func marked(for product: String) -> Bool {
        let want = product.lowercased()
        if slicedFor?.lowercased() == want { return true }
        return alsoMarkedFor.contains { $0.lowercased() == want }
    }
}

/// One row of the profile picker.
struct MWProfileRow: Identifiable, Hashable, Sendable {
    /// The instance id. MakerWorld's `defaultInstanceId` is one of THESE, not a `profileId`.
    let id: Int
    /// What `POST /makerworld/import` wants.
    var profileId: Int?
    var title: String
    var coverUrl: String?
    /// `nil` when MakerWorld publishes no metadata for this profile.
    ///
    /// On model 40146 that is **51 of 88 rows**, including the one MakerWorld itself pre-selects. The
    /// picker must say so in words; rendering "—" for time and no swatches is what made every row on
    /// every model look broken. The profiles are still real and still importable.
    var detail: MWProfileDetail?
    /// The uploader's own blurb for THIS profile, reduced to plain text. `nil` when they wrote none
    /// — which is most of them, so the preview must not reserve space for it.
    ///
    /// Plain because this is what gets *tested*: the "has notes" check, the photos-or-notes filter
    /// and the length used to decide whether a More control is worth showing. Rendering uses
    /// `summaryHTML`, so formatting survives on screen without markup leaking into predicates.
    var summary: String?
    /// The blurb to render — MakerWorld's translation when it has one, else the author's own — and
    /// which of the two it is. Kept beside the plain form rather than replacing it: one is for
    /// reading, the other for deciding.
    var description: MakerWorldSearch.Description?
    /// Extra photos attached to this profile, beyond `coverUrl`. Usually empty.
    var pictures: [String] = []
}

// MARK: - Licence

/// A licence as MakerWorld states it, plus the one obligation that bites here.
struct MWLicence: Equatable, Sendable {
    /// The raw code, e.g. `"BY-ND"` or `"Standard Digital File License"`.
    var code: String
    /// MakerWorld's own prose, when it ships it. Rendered verbatim — never paraphrased.
    var title: String?
    var body: String?

    init(code: String, title: String? = nil, body: String? = nil) {
        self.code = code
        self.title = title
        self.body = body
    }

    /// The Creative Commons clauses, when this is a CC code at all — `["BY", "NC", "ND"]`.
    ///
    /// Split on the separator rather than searched for as substrings: `"Standard Digital File
    /// License"` **contains** "ND", and matching it that way labelled MakerWorld's own proprietary
    /// licence as no-derivatives. Clause codes are tokens, not spellings.
    private var ccClauses: Set<String>? {
        let parts = code.uppercased().split(separator: "-").map(String.init)
        guard parts.first == "BY" else { return nil }
        return Set(parts)
    }

    /// A short human label for the chip. CC codes arrive bare; anything else is already prose.
    var label: String {
        ccClauses == nil ? code : "CC " + code.uppercased()
    }

    /// The single line shown under the import button.
    ///
    /// Personal printing is permitted by every licence observed on MakerWorld, so this is not a
    /// warning about the print — it is about what happens afterwards. Sprout adds no share, export or
    /// re-upload affordance, which is the obligation that actually bites; if one is ever added it has
    /// to be gated per-licence.
    var obligation: String {
        guard let clauses = ccClauses else {
            return "Personal prints only — the file may not be redistributed."
        }
        if clauses.contains("ND") { return "Personal prints only — no modified versions may be shared." }
        if clauses.contains("NC") { return "Personal, non-commercial prints. Credit the creator if you share photos." }
        return "Credit the creator if you share this model or photos of it."
    }
}

/// Hints that an import might be refused. None of them is an answer — a `403` at import is.
struct MWAvailability: Equatable, Sendable {
    var isPaid = false
    var isPointRedeemable = false
    var isExclusive = false

    var caution: String? {
        if isPaid { return "This is a paid model. If you haven’t bought it, the import will be refused." }
        if isPointRedeemable { return "This model is redeemed with MakerWorld points. The import may be refused." }
        if isExclusive { return "This model is marked exclusive. The import may be refused." }
        return nil
    }
}

// MARK: - Failures

/// What went wrong, in words, plus whether the escape hatch is worth offering.
///
/// Two networks fail here independently — phone→Bambuddy and Bambuddy→MakerWorld — and the message
/// must not blame the wrong one. "Import failed" for a paid model, when MakerWorld sent a perfectly
/// good sentence explaining that it is paid, is the app throwing away the only useful information it
/// received.
struct MWFailure: Equatable, Sendable {
    var message: String
    /// Whether to offer **Open on MakerWorld**. True for everything the server cannot fix by
    /// retrying — a browser session can often do what a backend cannot.
    var offerWebLink: Bool
}

// MARK: - The join

enum MakerWorld {

    /// Which call failed. The same status means different things on either side of an import.
    enum Step: Equatable, Sendable { case resolve, importing }

    /// Map an HTTP status plus the API's own `detail` sentence to something worth reading.
    ///
    /// MakerWorld's refusals are forwarded verbatim by Bambuddy and are BETTER than anything written
    /// here — they name the actual reason (paid, points, region, early access). They are passed
    /// through untouched.
    static func failure(step: Step, status: Int, detail: String?) -> MWFailure {
        let d = detail?.nonEmpty
        let lower = (d ?? "").lowercased()

        switch status {
        case 400 where step == .resolve:
            return MWFailure(message: "That doesn’t look like a MakerWorld model link. Paste one that "
                             + "looks like makerworld.com/models/1400373.", offerWebLink: false)
        case 400:
            return MWFailure(message: undownloadableProfile, offerWebLink: true)
        case 404:
            return MWFailure(message: "MakerWorld has no model at that link.", offerWebLink: false)
        case 401 where step == .resolve:
            // Resolving is anonymous upstream — no Bambu Cloud token is involved — so the only 401
            // producible here is Bambuddy rejecting THIS APP's key. Sending the user to re-do a cloud
            // sign-in would have them fix something that was never used.
            return MWFailure(message: d ?? "Your Bambuddy server rejected this app’s API key. Re-enter "
                             + "it in Settings.", offerWebLink: false)
        case 401:
            return MWFailure(message: d ?? "MakerWorld rejected your server’s Bambu Cloud sign-in. Sign "
                             + "in again under Bambuddy → Profiles → Cloud Profiles.", offerWebLink: false)
        case 403:
            // MakerWorld's own words. Never replaced with "import failed".
            return MWFailure(message: d ?? "MakerWorld won’t release this file to your account.",
                             offerWebLink: true)
        case 429:
            return MWFailure(message: "MakerWorld is rate-limiting your server. Try again shortly.",
                             offerWebLink: true)
        default:
            if lower.contains("robot") || lower.contains("captcha") {
                return MWFailure(message: "MakerWorld is challenging your server’s IP with a CAPTCHA, "
                                 + "which it can’t answer. This usually clears in a few hours.",
                                 offerWebLink: true)
            }
            if lower.contains("200 mb") || lower.contains("exceeds") {
                return MWFailure(message: "This model is over the 200 MB import limit.", offerWebLink: true)
            }
            if status == 0 {
                return MWFailure(message: "Couldn’t reach your Bambuddy server.", offerWebLink: false)
            }
            if step == .importing {
                // The refusal measured in practice arrives HERE, not as a 400: Bambuddy wraps
                // MakerWorld's status in a 502 of its own (`{"detail": "Bambu Lab API unexpected
                // status 400 for profile …"}`), and through a tunnelling proxy even that detail is
                // replaced by the proxy's own error page — so this arm has to stand on its own words.
                // Its own words are also better than the wrapper's, which names a status and explains
                // nothing.
                if let d, !lower.contains("unexpected status") {
                    return MWFailure(message: d, offerWebLink: true)
                }
                return MWFailure(message: undownloadableProfile, offerWebLink: true)
            }
            return MWFailure(message: d ?? "Your Bambuddy server couldn’t look up this model on MakerWorld.",
                             offerWebLink: true)
        }
    }

    /// Measured: MakerWorld lists profiles it will not release a file for. Five of six undescribed
    /// profiles on model 40146 were refused, including the one MakerWorld itself pre-selects, while
    /// every profile with published details downloaded. The listing is not a promise, so the copy
    /// points at the next thing to try rather than reporting a dead end.
    private static let undownloadableProfile =
        "Your Bambuddy server couldn’t download this profile. MakerWorld lists profiles it won’t "
        + "release a file for — try one that shows print details."

    /// Reduce the two probes to one answer.
    ///
    /// `canDownload` is the server's own answer to *"will an import find a token?"* — the exact
    /// capability — so a `true` needs no further diagnosis. The cloud probe is only consulted to
    /// explain a `false`, which is the whole point of asking it: one boolean cannot carry three
    /// remedies. `nil` means the question could not be asked.
    static func access(cloud: MakerWorldCloudProbe, canDownload: Bool?) -> MakerWorldAccess {
        if canDownload == true { return .ready }
        switch cloud {
        case .forbidden:
            return .keyLacksCloudScope
        case .readable(let authenticated):
            guard authenticated else { return .serverNotSignedIn }
            // `/cloud/status` checks expiry, so an authenticated `200` is itself a usable-token
            // answer — enough to try the import when `/makerworld/status` never replied. When it did
            // reply `false`, the more specific endpoint wins.
            return canDownload == false ? .serverNotSignedIn : .ready
        case .failed:
            return .unreachable
        }
    }

    /// Build the picker's rows from a resolve response.
    ///
    /// **Direction matters.** `POST /resolve` returns two lists that overlap: `instances` (the hits
    /// from `GET /design/{id}/instances`) and `design.instances` (records carried inside the design).
    /// Measured on the live API, the hits are a strict superset — 88 vs 37 on model 40146, with zero
    /// record-only profiles — while only the records carry `prediction`, `weight`, `needAms` and
    /// `instanceFilaments`.
    ///
    /// So the hits are the ROW SET and the records are a metadata sidecar. Building rows from the
    /// records instead would drop 51 real, named, importable profiles the owner can see on the
    /// website — the recurring bug running in reverse, hiding a capability that exists.
    /// A profile's blurb, unless it merely repeats the title.
    ///
    /// MakerWorld auto-names most profiles after their slicer settings — "0.2mm layer, 2 walls, 15%
    /// infill" — and uploaders routinely paste the same sentence into the description. Rendering
    /// both puts the identical line on screen twice, one inch apart, which reads as a rendering
    /// fault. Compared loosely, because the two differ by trailing whitespace as often as not.
    private static func blurb(_ html: String?, title: String) -> String? {
        guard let text = MakerWorldSearch.plainText(html) else { return nil }
        let normalise = { (s: String) in
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return normalise(text) == normalise(title) ? nil : text
    }

    /// Photos beyond the cover, de-duplicated against it.
    ///
    /// `pictures` routinely repeats the cover as its first entry, and a preview that shows the same
    /// image twice reads as a rendering fault rather than a gallery.
    ///
    /// Both covers are excluded, because the row shows the HIT's cover while `pictures` lives on the
    /// RECORD, and the two are not always the same string. De-duplicating against only one of them
    /// is exactly the near-miss predicate this codebase keeps shipping.
    private static func extraPictures(_ record: MWInstance?, shownCover: String?) -> [String] {
        guard let record else { return [] }
        var seen = Set([record.cover, shownCover].compactMap { $0 })
        var out: [String] = []
        for url in (record.pictures ?? []).compactMap(\.url) where !url.isEmpty && !seen.contains(url) {
            seen.insert(url)
            out.append(url)
        }
        return out
    }

    static func rows(_ resolved: MakerWorldResolved) -> [MWProfileRow] {
        let records = resolved.design.instances ?? []
        var byProfile: [Int: MWInstance] = [:]
        for r in records {
            guard let pid = r.profileId else { continue }
            // First wins: a duplicate profileId is upstream noise, not a second profile.
            if byProfile[pid] == nil { byProfile[pid] = r }
        }

        var rows = resolved.instances.map { hit in
            MWProfileRow(
                id: hit.id,
                profileId: hit.profileId,
                title: title(hit),
                coverUrl: hit.cover,
                detail: hit.profileId.flatMap { byProfile[$0] }.flatMap(detail),
                summary: blurb(hit.profileId.flatMap { byProfile[$0] }?.summary, title: title(hit)),
                description: blurb(hit.profileId.flatMap { byProfile[$0] }?.summary, title: title(hit)) == nil
                    ? nil
                    : MakerWorldSearch.description(
                        original: hit.profileId.flatMap { byProfile[$0] }?.summary,
                        translated: hit.profileId.flatMap { byProfile[$0] }?.summaryTranslated),
                pictures: extraPictures(hit.profileId.flatMap { byProfile[$0] }, shownCover: hit.cover)
            )
        }

        // Defensive, and only defensive: no record-only profile has ever been measured. If upstream
        // ever ships one, losing it silently would be the same bug in miniature.
        //
        // Both keys are checked. Membership on `profileId` alone let a record whose id collides with
        // an existing ROW id through, and `MWProfileRow` is Identifiable by instance id — duplicate
        // ids in a ForEach are undefined behaviour, not a cosmetic duplicate.
        let seen = Set(resolved.instances.compactMap(\.profileId))
        let seenIds = Set(rows.map(\.id))
        for r in records where (r.profileId.map { !seen.contains($0) } ?? false) && !seenIds.contains(r.id) {
            rows.append(MWProfileRow(id: r.id, profileId: r.profileId, title: title(r),
                                     coverUrl: r.cover, detail: detail(r),
                                     summary: blurb(r.summary, title: title(r)),
                                     description: blurb(r.summary, title: title(r)) == nil ? nil
                                        : MakerWorldSearch.description(original: r.summary,
                                                                       translated: r.summaryTranslated),
                                     pictures: extraPictures(r, shownCover: r.cover)))
        }
        return rows
    }

    /// Which row to select first.
    ///
    /// `design.defaultInstanceId` is MakerWorld's own answer, and it is an **instance id** — matching
    /// it against `profileId`, or looking for it among the records where it is often absent entirely,
    /// silently never fires. `isDefault` is not a fallback either: it was false on every record of
    /// every model probed, so it is dead weight rather than a second chance.
    ///
    /// MakerWorld's choice is honoured only when that profile publishes details, because a profile
    /// that publishes none is measurably likely to refuse the download — on model 40146 the
    /// pre-selected profile answers `400`. Pre-selecting a row whose import cannot work would hand
    /// the user a failure as the default action.
    static func preselect(_ rows: [MWProfileRow], defaultInstanceId: Int?) -> MWProfileRow? {
        let theirs = defaultInstanceId.flatMap { want in rows.first { $0.id == want } }
        if theirs?.detail != nil { return theirs }
        // Then the simplest thing that describes itself — single-filament first, because that is what
        // the wizard can carry end to end today.
        if let described = rows.first(where: { $0.detail?.slotCount == 1 }) { return described }
        if let described = rows.first(where: { $0.detail != nil }) { return described }
        // Nothing is described: fall back to their pick, then to the top of the list.
        return theirs ?? rows.first
    }

    /// `https://makerworld.com/models/{id}` — the escape hatch offered on every terminal failure.
    static func webUrl(modelId: Int) -> URL? {
        URL(string: "https://makerworld.com/models/\(modelId)")
    }

    static func licence(_ design: MWDesign) -> MWLicence? {
        guard let code = design.license?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty
        else { return nil }
        // MakerWorld sends `{"title":"","content":""}` rather than omitting the object, so an empty
        // string here means "no prose", not "prose that is empty".
        return MWLicence(code: code,
                         title: design.licenseDescriptionInfo?.title?.nonEmpty,
                         body: design.licenseDescriptionInfo?.content?.nonEmpty)
    }

    static func availability(_ design: MWDesign) -> MWAvailability {
        MWAvailability(isPaid: design.paidSetting?.isPaid ?? false,
                       isPointRedeemable: design.isPointRedeemable ?? false,
                       isExclusive: design.isExclusive ?? false)
    }

    // MARK: Row text

    /// `"3h 42m · 322 g · AMS · 4 plates"`, or the honest empty state.
    static func metaLine(_ detail: MWProfileDetail?) -> String {
        guard let d = detail else { return "MakerWorld publishes no details for this profile" }
        var parts: [String] = []
        if let s = d.seconds, s > 0 { parts.append(Dash.fmtDuration(s / 60)) }
        if let g = d.grams, g > 0 { parts.append("\(fmt(g)) g") }
        if d.needAms { parts.append("AMS") }
        if d.plateCount > 1 { parts.append("\(d.plateCount) plates") }
        // A record with every numeric field empty is still a described profile — say what is known
        // rather than falling back to the "no details" line, which would be untrue.
        return parts.isEmpty ? "No print estimate published" : parts.joined(separator: "  ·  ")
    }

    /// `"0.25 mm · PLA ×2 + PETG · 3 colours"`. Empty when there is nothing to say.
    static func materialsLine(_ detail: MWProfileDetail?) -> String {
        guard let d = detail else { return "" }
        var parts: [String] = []
        if let lh = d.layerHeight?.nonEmpty { parts.append("\(lh) mm") }

        // Group by material in first-seen order: "PLA ×2 + PETG" reads better than a bare count and
        // is the thing that decides whether a spool has to be swapped.
        var order: [String] = []
        var counts: [String: Int] = [:]
        for s in d.slots {
            let t = (s.type?.nonEmpty ?? "?").uppercased()
            if counts[t] == nil { order.append(t) }
            counts[t, default: 0] += 1
        }
        if !order.isEmpty {
            parts.append(order.map { counts[$0] == 1 ? $0 : "\($0) ×\(counts[$0]!)" }.joined(separator: " + "))
        }
        if let colors = d.colorCount, colors > 1 { parts.append("\(colors) colours") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Internals

    private static func title(_ i: MWInstance) -> String {
        i.title?.nonEmpty ?? "Default profile"
    }

    private static func detail(_ i: MWInstance) -> MWProfileDetail? {
        let info = i.extention?.modelInfo
        let plates = info?.plates ?? []
        // MakerWorld puts per-profile numbers on the record and, on some models, only on its first
        // plate. Both are read at every site.
        let slots = (i.instanceFilaments ?? plates.first?.filaments ?? []).map {
            MWSlot(type: $0.type, color: $0.color, grams: Double($0.usedG ?? ""))
        }
        return MWProfileDetail(
            seconds: i.prediction?.double ?? plates.first?.prediction?.double,
            grams: i.weight?.double ?? plates.first?.weight?.double,
            needAms: i.needAms ?? false,
            slots: slots,
            materialCount: i.materialCnt,
            colorCount: i.materialColorCnt,
            plateCount: max(plates.count, 1),
            layerHeight: info?.projectSettings?.layerHeight,
            slicedFor: info?.compatibility?.devProductName,
            alsoMarkedFor: (info?.otherCompatibility ?? []).compactMap(\.devProductName)
        )
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

extension String {
    /// `nil` for an empty or whitespace-only string, so `??` chains skip it.
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
