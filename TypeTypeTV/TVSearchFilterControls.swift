import SwiftUI

struct TVSearchFilterControls: View {
    let capabilities: TVSearchFiltersResponse
    @Binding var contentFilter: String
    @Binding var sortFilter: String
    @Binding var selectedGroups: [String: Set<String>]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("search.filters").font(.callout.bold())
                .foregroundStyle(TTTheme.muted)
            HStack(spacing: 18) {
                if !capabilities.contentFilters.isEmpty {
                    Picker("search.contentType", selection: $contentFilter) {
                        Text("search.all").tag("")
                        ForEach(capabilities.contentFilters) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if !capabilities.sortFilters.isEmpty {
                    Picker("search.sort", selection: $sortFilter) {
                        Text("search.default").tag("")
                        ForEach(capabilities.sortFilters) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                }
                ForEach(capabilities.filterGroups) { group in
                    if group.multiSelect {
                        Menu {
                            ForEach(group.options) { option in
                                Button {
                                    var chosen = selectedGroups[group.key] ?? []
                                    if chosen.contains(option.value) { chosen.remove(option.value) }
                                    else { chosen.insert(option.value) }
                                    selectedGroups[group.key] = chosen
                                } label: {
                                    Label(option.label, systemImage:
                                          selectedGroups[group.key]?.contains(option.value) == true
                                          ? "checkmark.circle.fill" : "circle")
                                }
                            }
                        } label: {
                            Label(group.label, systemImage: "line.3.horizontal.decrease.circle")
                        }
                    } else {
                        Picker(group.label, selection: Binding<String>(
                            get: { selectedGroups[group.key]?.first ?? "" },
                            set: { selectedGroups[group.key] = $0.isEmpty ? [] : [$0] }
                        )) {
                            Text("search.all").tag("")
                            ForEach(group.options) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            .buttonStyle(.bordered)
        }
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
