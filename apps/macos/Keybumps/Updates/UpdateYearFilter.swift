import Foundation
import Sparkle

/// An appcast item as the update year sees it.
struct UpdateCandidate: Equatable {
    /// Sparkle's version (`sparkle:version`, the build), which orders releases.
    let version: String
    let displayVersion: String
    /// `<keybumps:releaseDate>`, which the release script adds. Items without one, every release
    /// before ADR 0011, count as covered.
    let releaseDate: Date?
    /// Whether this Mac's macOS can run it.
    let runsHere: Bool
}

extension UpdateCandidate {
    /// The name Sparkle gives `<keybumps:releaseDate>` in an item's properties: an element outside
    /// Sparkle's namespace keeps its prefixed name.
    static let releaseDateKey = "keybumps:releaseDate"

    init(item: SUAppcastItem) {
        self.init(
            version: item.versionString,
            displayVersion: item.displayVersionString,
            releaseDate: (item.propertiesDictionary[Self.releaseDateKey] as? String).flatMap(PolarDates.parse),
            runsHere: item.minimumOperatingSystemVersionIsOK && item.maximumOperatingSystemVersionIsOK
        )
    }
}

/// Which appcast item Sparkle may install under the license's update year (ADR 0011). An item
/// released after the year is never offered for installing; the newest such one is shown instead,
/// with Renew. With no update year known, or nothing it leaves out, Sparkle picks as it always has.
enum UpdateYearFilter {
    enum Pick: Equatable {
        /// Let Sparkle choose, as without a delegate.
        case sparkle
        /// Install this candidate.
        case candidate(Int)
        /// No update to install.
        case nothing
    }

    struct Choice: Equatable {
        var pick: Pick
        /// The newest version that only a renewal installs.
        var renewalVersion: String?
    }

    static func choose(
        _ candidates: [UpdateCandidate],
        hostVersion: String,
        updateYear: UpdateYear?,
        compare: (String, String) -> ComparisonResult = SUStandardVersionComparator.default.compareVersion(_:toVersion:)
    ) -> Choice {
        guard let updateYear else { return Choice(pick: .sparkle) }
        func isCovered(_ candidate: UpdateCandidate) -> Bool {
            candidate.releaseDate.map(updateYear.covers(releaseDate:)) ?? true
        }
        func isNewer(_ candidate: UpdateCandidate) -> Bool {
            compare(hostVersion, candidate.version) == .orderedAscending
        }
        func isOlder(_ a: UpdateCandidate, _ b: UpdateCandidate) -> Bool {
            compare(a.version, b.version) == .orderedAscending
        }
        let needsRenewal = candidates.filter { !isCovered($0) && $0.runsHere && isNewer($0) }
        guard let newest = needsRenewal.max(by: isOlder) else { return Choice(pick: .sparkle) }
        let best = candidates.indices.filter { isCovered(candidates[$0]) }.max { isOlder(candidates[$0], candidates[$1]) }
        guard let best, isNewer(candidates[best]) else {
            return Choice(pick: .nothing, renewalVersion: newest.displayVersion)
        }
        return Choice(pick: .candidate(best), renewalVersion: newest.displayVersion)
    }

    /// Whether Check for Updates… should check quietly: once the update year has ended, a newer
    /// version needs a renewal, and Sparkle's own alert would call Keybumps up to date.
    static func checksQuietly(updateYear: UpdateYear?, now: Date) -> Bool {
        updateYear?.hasEnded(at: now) == true
    }
}
