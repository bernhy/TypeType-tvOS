import SwiftUI

/// Filter labels from NewPipe are API identifiers (e.g. "upload_date",
/// "past_week", "HD"), not user-facing localized display strings.
/// The opaque 'value' is sent unchanged to the server.
struct TVSearchFilterControls: View {
    let capabilities: TVSearchFiltersResponse
    @Binding var contentFilter: String
    @Binding var sortFilter: String
    @Binding var selectedGroups: [String: Set<String>]

    private var serverHasSortGroup: Bool {
        capabilities.filterGroups.contains { TVSearchFilterTexts.groupID($0.key) == "sortby" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("search.filters")
                .font(.callout.bold())
                .foregroundStyle(TTTheme.muted)
            HStack(alignment: .top, spacing: 20) {
                if !capabilities.contentFilters.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("search.contentType")
                            .font(.caption.bold()).foregroundStyle(TTTheme.muted)
                        Picker("search.contentType", selection: $contentFilter) {
                            Text("search.all").tag("")
                            ForEach(TVSearchFilterTexts.choices(capabilities.contentFilters)) { item in
                                Text(TVSearchFilterTexts.option(item.label))
                                    .tag(item.value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                // The server exposes the very same sort choices in BOTH
                // sortFilters and filterGroups["sortby"]. Only one control
                // must be rendered, or mutually exclusive values conflict.
                if !serverHasSortGroup && !capabilities.sortFilters.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("search.sort")
                            .font(.caption.bold()).foregroundStyle(TTTheme.muted)
                        Picker("search.sort", selection: $sortFilter) {
                            Text("search.default").tag("")
                            ForEach(TVSearchFilterTexts.choices(capabilities.sortFilters)) { item in
                                Text(TVSearchFilterTexts.option(item.label))
                                    .tag(item.value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                ForEach(capabilities.filterGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(TVSearchFilterTexts.group(group.label))
                            .font(.caption.bold()).foregroundStyle(TTTheme.muted)
                        if group.multiSelect {
                            Menu {
                                ForEach(TVSearchFilterTexts.choices(group.options)) { item in
                                    Button {
                                        var chosen = selectedGroups[group.key] ?? []
                                        if chosen.contains(item.value) { chosen.remove(item.value) }
                                        else { chosen.insert(item.value) }
                                        selectedGroups[group.key] = chosen
                                    } label: {
                                        Label(
                                            TVSearchFilterTexts.option(item.label),
                                            systemImage: selectedGroups[group.key]?.contains(item.value) == true
                                                ? "checkmark.circle.fill" : "circle"
                                        )
                                    }
                                }
                            } label: {
                                Label(
                                    TVL10n.formatted(
                                        "search.filterSelectedCount",
                                        selectedGroups[group.key]?.count ?? 0
                                    ),
                                    systemImage: "line.3.horizontal.decrease.circle"
                                )
                            }
                        } else {
                            Picker(group.label, selection: Binding<String>(
                                get: { selectedGroups[group.key]?.first ?? "" },
                                set: { selectedGroups[group.key] = $0.isEmpty ? [] : [$0] }
                            )) {
                                if TVSearchFilterTexts.groupID(group.key) == "sortby" {
                                    Text("search.default").tag("")
                                } else {
                                    Text("search.all").tag("")
                                }
                                ForEach(TVSearchFilterTexts.choices(group.options)) { item in
                                    Text(TVSearchFilterTexts.option(item.label)).tag(item.value)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .focusSection()
        }
    }
}

/// Keep the complete server 'value', localize only the human-readable label.
/// Unknown future NewPipe labels are made readable rather than silently
/// translated to the wrong concept. Do not synthesize localization keys:
/// our project validator requires each key to be statically discoverable.
enum TVSearchFilterTexts {
    /// The server supplies an explicit default (usually "all") *and* the
    /// client has an empty-value default. Keep exactly one displayed choice.
    static func choices(_ options: [TVSearchFilterOption]) -> [TVSearchFilterOption] {
        options.filter { option in
            let name = normalized(option.label)
            // "All" and the sort defaults are already represented by our
            // synthetic picker item. A default "Videos" content type is NOT
            // equivalent to "All" and must stay selectable.
            return name != "all" &&
                !(option.isDefault == true &&
                  ["sortrelevance", "sortdefault", "relevance"].contains(name))
        }
    }

    static func groupID(_ key: String) -> String {
        key.split(separator: "|", omittingEmptySubsequences: false)
            .first.map(String.init)?.lowercased() ?? key.lowercased()
    }

    static func group(_ raw: String) -> String {
        switch normalized(raw) {
        case "sortby": return TVL10n.value("search.sort")
        case "uploaddate": return TVL10n.value("search.filterUploadDate")
        case "duration": return TVL10n.value("search.filterDuration")
        case "features": return TVL10n.value("search.filterFeatures")
        case "type", "content": return TVL10n.value("search.contentType")
        default: return readable(raw)
        }
    }

    static func option(_ raw: String) -> String {
        let tail = raw.split(separator: ":", maxSplits: 1).last.map(String.init) ?? raw
        switch normalized(tail) {
        case "all": return TVL10n.value("search.all")
        case "videos", "video": return TVL10n.value("search.filterVideos")
        case "channels", "channel": return TVL10n.value("search.channels")
        case "playlists", "playlist": return TVL10n.value("search.filterPlaylists")
        case "livestreams", "lives", "live": return TVL10n.value("search.filterLive")
        case "sortrelevance", "relevance", "sortdefault": return TVL10n.value("search.filterRelevance")
        case "sortupload", "sortdate", "sortnewest": return TVL10n.value("search.filterNewest")
        case "sortview", "sortviews": return TVL10n.value("search.filterMostViewed")
        case "sortrating", "sortrated": return TVL10n.value("search.filterRating")
        case "pasthour": return TVL10n.value("search.filterPastHour")
        case "pastday": return TVL10n.value("search.filterPastDay")
        case "pastweek": return TVL10n.value("search.filterPastWeek")
        case "pastmonth": return TVL10n.value("search.filterPastMonth")
        case "pastyear": return TVL10n.value("search.filterPastYear")
        case "shortvideo", "short": return TVL10n.value("search.filterShort")
        case "longvideo", "long": return TVL10n.value("search.filterLong")
        case "mediumvideo", "medium": return TVL10n.value("search.filterMedium")
        case "subtitles", "captions", "cc": return TVL10n.value("search.filterSubtitles")
        case "hd": return TVL10n.value("search.filterHD")
        case "4k", "uhd": return TVL10n.value("search.filter4K")
        case "hdr": return TVL10n.value("search.filterHDR")
        case "360": return TVL10n.value("search.filter360")
        case "3d": return TVL10n.value("search.filter3D")
        case "vr180": return TVL10n.value("search.filterVR180")
        case "location": return TVL10n.value("search.filterLocation")
        case "purchased": return TVL10n.value("search.filterPurchased")
        case "creativecommons": return TVL10n.value("search.filterCreativeCommons")
        default: return readable(tail)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func readable(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCapitalized
    }
}

struct TVSearchNamedCard: View {
    let title: String
    let subtitle: String?
    let image: URL?
    let origin: URL
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                TVThumbnail(url: image, origin: origin)
                Image(systemName: symbol)
                    .font(.system(size: 37, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(15)
                    .background(.black.opacity(0.68),
                                in: RoundedRectangle(cornerRadius: 16))
            }
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(title).font(.headline).lineLimit(2)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).lineLimit(2)
                    .foregroundStyle(TTTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
