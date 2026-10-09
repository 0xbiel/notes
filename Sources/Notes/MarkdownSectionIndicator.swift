import AppKit
import SwiftUI

struct MarkdownSection: Identifiable, Equatable {
    var id: Int { range.location }
    let title: String
    let level: Int
    let range: NSRange

    static func parse(_ text: String) -> [MarkdownSection] {
        var result: [MarkdownSection] = []
        var offset = 0
        var fence: (Character, Int)?
        let heading = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+(.*)|[ \t]*)$"#)
        for line in text.components(separatedBy: "\n") {
            defer { offset += line.utf16.count + 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "`" || first == "~" {
                let length = trimmed.prefix(while: { $0 == first }).count
                if let open = fence {
                    if first == open.0, length >= open.1, trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    continue
                } else if length >= 3 { fence = (first, length); continue }
            }
            guard fence == nil,
                  let match = heading.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) else { continue }
            let source = line as NSString
            let raw = match.range(at: 2).location == NSNotFound ? "" : source.substring(with: match.range(at: 2))
            let title = raw.replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let rendered = InlineUnderline.attributed(title)
            result.append(.init(title: String(rendered.characters), level: match.range(at: 1).length,
                                range: NSRange(location: offset, length: line.utf16.count)))
        }
        return result
    }
}

enum MarkdownSectionNavigation {
    static func visibleIDs(sections: [MarkdownSection], positions: [CGFloat], documentHeight: CGFloat, viewport: CGRect) -> Set<Int> {
        guard viewport.height > 0, positions.count == sections.count else { return [] }
        return Set(sections.enumerated().compactMap { index, section in
            let end = index + 1 < positions.count ? positions[index + 1] : documentHeight
            return end > viewport.minY && positions[index] < viewport.maxY ? section.id : nil
        })
    }

    static func path(to id: Int?, in sections: [MarkdownSection]) -> [MarkdownSection] {
        var path: [MarkdownSection] = []
        for section in sections {
            while let last = path.last, last.level >= section.level { path.removeLast() }
            path.append(section)
            if section.id == id { return path }
        }
        return []
    }

    static func overview(_ sections: [MarkdownSection], currentID: Int?) -> [MarkdownSection] {
        guard sections.count > 16 else { return sections }
        var level = 2
        var major = sections.filter { $0.level <= level }
        while major.count < 2 && level < 6 {
            level += 1
            major = sections.filter { $0.level <= level }
        }
        guard major.count > 20 else { return major }
        // Keep a readable overview on large outlines, including the active branch.
        var indexes = Set((0..<19).map { Int((Double($0) * Double(major.count - 1) / 18).rounded()) })
        if let current = activeID(currentID, in: sections, overview: major),
           let index = major.firstIndex(where: { $0.id == current }) { indexes.insert(index) }
        return indexes.sorted().map { major[$0] }
    }

    static func activeID(_ currentID: Int?, in sections: [MarkdownSection], overview: [MarkdownSection]) -> Int? {
        let ancestors = Set(path(to: currentID, in: sections).map(\.id))
        return overview.last { ancestors.contains($0.id) }?.id
    }

    static func initiallyExpanded(_ sections: [MarkdownSection], currentID: Int?) -> Set<Int> {
        var expanded = Set(path(to: currentID, in: sections).dropLast().map(\.id))
        if let level = sections.map(\.level).min() {
            let roots = sections.filter { $0.level == level }
            if roots.count == 1 { expanded.insert(roots[0].id) }
        }
        return expanded
    }

    static func visible(_ sections: [MarkdownSection], expanded: Set<Int>, search: String) -> [MarkdownSection] {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sections.filter { $0.title.localizedCaseInsensitiveContains(search.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        var ancestors: [MarkdownSection] = []
        return sections.filter { section in
            while let last = ancestors.last, last.level >= section.level { ancestors.removeLast() }
            let visible = ancestors.allSatisfy { expanded.contains($0.id) }
            ancestors.append(section)
            return visible
        }
    }
}

@MainActor final class MarkdownSectionState: ObservableObject {
    @Published var sections: [MarkdownSection] = []
    @Published var visibleIDs: Set<Int> = []
    var overviewVisibleIDs: Set<Int> {
        let displayed = overview
        return Set(visibleIDs.compactMap { MarkdownSectionNavigation.activeID($0, in: sections, overview: displayed) })
    }
    @Published var currentID: Int?
    var overview: [MarkdownSection] { MarkdownSectionNavigation.overview(sections, currentID: currentID) }
    var overviewCurrentID: Int? { MarkdownSectionNavigation.activeID(currentID, in: sections, overview: overview) }
    @Published var accent = NSColor.controlAccentColor
    var navigate: ((MarkdownSection) -> Void)?
}

enum MarkdownSectionEmphasis {
    static func width(index: Int, hoveredIndex: Int?) -> CGFloat {
        guard let hoveredIndex else { return 12 }
        let distance = Double(index - hoveredIndex)
        return 12 + 16 * exp(-(distance * distance) / (2 * 1.15 * 1.15))
    }
}

struct MarkdownSectionIndicator: View {
    @ObservedObject var state: MarkdownSectionState
    @AppStorage("notes.language") private var language = "es"
    @State private var hoveredID: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var outlinePresented = false
    @State private var rowFrames: [Int: CGRect] = [:]
    @State private var tooltipHeight: CGFloat = 80
    private var hoveredIndex: Int? { state.overview.firstIndex { $0.id == hoveredID } }
    private let rowHeight: CGFloat = 11
    init(state: MarkdownSectionState, initialHoveredID: Int? = nil) {
        self.state = state
        _hoveredID = State(initialValue: initialHoveredID)
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button { outlinePresented.toggle() } label: {
                Image(systemName: "list.bullet").font(.system(size: 12))
                    .foregroundStyle(.secondary).frame(width: 12, height: 25)
                    .frame(width: 32, alignment: .trailing).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("document.sectionPicker")
                .accessibilityLabel(language == "en" ? "Browse sections" : "Explorar secciones")
                .help(language == "en" ? "Browse sections" : "Explorar secciones")
                .popover(isPresented: $outlinePresented, arrowEdge: .leading) {
                    MarkdownSectionPicker(state: state) { outlinePresented = false }
                }
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(state.overview.enumerated()), id: \.element.id) { index, section in
                        Button { state.navigate?(section) } label: {
                            HStack {
                                Spacer(minLength: 0)
                                Capsule()
                                    .fill(hoveredID == section.id ? Color(state.accent) : (state.overviewVisibleIDs.contains(section.id) ? Color.primary : Color.secondary.opacity(0.45)))
                                    .frame(width: MarkdownSectionEmphasis.width(index: index, hoveredIndex: hoveredIndex), height: 1.5)
                            }.frame(width: 32, height: rowHeight).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .onHover { hoveredID = $0 ? section.id : (hoveredID == section.id ? nil : hoveredID) }
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: SectionRowFrames.self, value: [section.id: geometry.frame(in: .named("section-indicator"))])
                                }
                            }
                            .accessibilityLabel((language == "en" ? "Go to section: " : "Ir a la sección: ") + section.title)
                            .accessibilityAddTraits(state.overviewVisibleIDs.contains(section.id) ? .isSelected : [])
                            .id(section.id)
                    }
                }.frame(maxWidth: .infinity, alignment: .trailing).padding(.vertical, 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hoveredID)
            }.scrollIndicators(.hidden)
                .onChange(of: state.sections) { _, _ in hoveredID = nil; outlinePresented = false }
        }
        .coordinateSpace(name: "section-indicator")
        .onPreferenceChange(SectionRowFrames.self) { rowFrames = $0 }
        .overlay {
            GeometryReader { geometry in
                if let section = state.overview.first(where: { $0.id == hoveredID }), let row = rowFrames[section.id] {
                    sectionTooltip(section)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tooltipHeight = $0 }
                        .position(x: geometry.size.width - 43 - 115,
                                  y: MarkdownSectionTooltip.center(rowY: row.midY, height: tooltipHeight, availableHeight: geometry.size.height))
                        .allowsHitTesting(false)
                }
            }
        }.accessibilityIdentifier("document.sectionIndicator")
    }
    private func sectionTooltip(_ section: MarkdownSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let path = MarkdownSectionNavigation.path(to: section.id, in: state.sections).dropLast()
            if !path.isEmpty {
                Text(path.map(\.title).joined(separator: " › "))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(section.title).font(.system(size: 12, weight: .medium)).lineLimit(3)
        }.multilineTextAlignment(.leading)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(width: 230, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .modifier(NotebookInputSurface(radius: 8, floating: true, opaque: true))
    }
}

private struct SectionRowFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

enum MarkdownSectionTooltip {
    static func center(rowY: CGFloat, height: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let half = height / 2
        return max(half, min(rowY, availableHeight - half))
    }
}

struct MarkdownSectionPicker: View {
    @ObservedObject var state: MarkdownSectionState
    var dismiss: () -> Void
    @AppStorage("notes.language") private var language = "es"
    @State private var search = ""
    @State private var expanded: Set<Int> = []
    @State private var hoveredID: Int?
    private var visible: [MarkdownSection] { MarkdownSectionNavigation.visible(state.sections, expanded: expanded, search: search) }
    private var currentPath: [MarkdownSection] { MarkdownSectionNavigation.path(to: state.currentID, in: state.sections) }
    private func hasChildren(_ section: MarkdownSection) -> Bool {
        guard let index = state.sections.firstIndex(where: { $0.id == section.id }), index + 1 < state.sections.count else { return false }
        return state.sections[index + 1].level > section.level
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(language == "en" ? "Search sections…" : "Buscar secciones…", text: $search)
                    .textFieldStyle(.plain).accessibilityIdentifier("document.searchSections")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel(language == "en" ? "Clear search" : "Borrar búsqueda")
                }
            }.padding(9)
            if !currentPath.isEmpty {
                Text(currentPath.map(\.title).joined(separator: " › "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, 9).padding(.bottom, 7)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visible) { section in
                            HStack(spacing: 2) {
                                if search.isEmpty && hasChildren(section) {
                                    Button {
                                        if !expanded.insert(section.id).inserted { expanded.remove(section.id) }
                                    } label: {
                                        Image(systemName: expanded.contains(section.id) ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                            .frame(width: 20, height: 30)
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel((expanded.contains(section.id) ? (language == "en" ? "Collapse: " : "Contraer: ") : (language == "en" ? "Expand: " : "Expandir: ")) + section.title)
                                } else { Color.clear.frame(width: 20, height: 1).accessibilityHidden(true) }
                                Button { state.navigate?(section); dismiss() } label: {
                                    HStack(spacing: 7) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(section.title).font(.system(size: 13, weight: section.level <= 2 ? .medium : .regular))
                                                .lineLimit(2).multilineTextAlignment(.leading)
                                            if !search.isEmpty {
                                                let parents = MarkdownSectionNavigation.path(to: section.id, in: state.sections).dropLast()
                                                if !parents.isEmpty {
                                                    Text(parents.map(\.title).joined(separator: " › "))
                                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                                }
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        if state.currentID == section.id {
                                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(state.accent))
                                        }
                                    }.padding(.horizontal, 6).padding(.vertical, 7)
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityIdentifier("document.goToSection." + String(section.id))
                                    .accessibilityAddTraits(state.currentID == section.id ? .isSelected : [])
                            }.padding(.leading, search.isEmpty ? CGFloat(max(0, MarkdownSectionNavigation.path(to: section.id, in: state.sections).count - 1)) * 12 : 0)
                                .background(state.currentID == section.id || hoveredID == section.id ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .onHover { hoveredID = $0 ? section.id : nil }.id(section.id)
                        }
                        if visible.isEmpty {
                            Text(language == "en" ? "No sections found" : "No se encontraron secciones")
                                .font(.callout).foregroundStyle(.secondary).padding(12)
                        }
                    }
                }.frame(height: min(340, CGFloat(max(1, visible.count)) * 40))
                    .onAppear {
                        expanded = MarkdownSectionNavigation.initiallyExpanded(state.sections, currentID: state.currentID)
                        DispatchQueue.main.async { if let id = state.currentID { proxy.scrollTo(id, anchor: .center) } }
                    }
            }
        }.padding(5).frame(width: 350).background(Color(nsColor: .windowBackgroundColor))
            .onExitCommand(perform: dismiss)
    }
}

/// Only the narrow rail intercepts the document's mouse events. Tooltip space
/// stays available for text selection and links when the tooltip is hidden.
@MainActor final class MarkdownSectionHostingView: NSHostingView<MarkdownSectionIndicator> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard local.x >= bounds.maxX - 38 else { return nil }
        return super.hitTest(point)
    }
}
