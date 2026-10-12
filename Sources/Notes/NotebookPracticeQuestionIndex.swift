import SwiftUI

struct NotebookPracticeScrollMetrics: Equatable {
    var questions: [String: CGRect] = [:]
    var content: CGRect? = nil

    func currentID(order: [String]) -> String? {
        order.first { (questions[$0]?.maxY ?? -.infinity) > 40 } ?? order.last { questions[$0] != nil }
    }

    func visibleIDs(height: CGFloat) -> Set<String> {
        guard height > 0 else { return [] }
        return Set(questions.compactMap { id, frame in frame.maxY > 0 && frame.minY < height ? id : nil })
    }

    func progress(height: CGFloat) -> Double {
        guard let content, content.height > height, height > 0 else { return 0 }
        return Double(max(0, min(1, -content.minY / (content.height - height))))
    }
}

struct NotebookPracticeScrollPreference: PreferenceKey {
    static let defaultValue = NotebookPracticeScrollMetrics()
    static func reduce(value: inout NotebookPracticeScrollMetrics, nextValue: () -> NotebookPracticeScrollMetrics) {
        let next = nextValue()
        value.questions.merge(next.questions, uniquingKeysWith: { _, new in new })
        if let content = next.content { value.content = content }
    }
}

@MainActor final class NotebookPracticeScrollState: ObservableObject {
    @Published private(set) var metrics = NotebookPracticeScrollMetrics()

    func update(_ value: NotebookPracticeScrollMetrics) {
        guard metrics != value else { return }
        metrics = value
    }
}

struct NotebookPracticeScrollIndex: View {
    @ObservedObject var state: NotebookPracticeScrollState
    let displays: [NotebookPracticeQuestionDisplay]
    let layout: NotebookPracticeLayout
    let flowID: String?
    let viewportHeight: CGFloat
    let bottomInset: CGFloat
    let text: NotebookPracticeText
    let tint: Color
    let navigate: (String) -> Void

    var body: some View {
        NotebookPracticeQuestionIndex(displays: displays,
            currentID: layout == .flow ? flowID : state.metrics.currentID(order: displays.map(\.id)),
            visibleIDs: layout == .flow ? Set(flowID.map { [$0] } ?? []) : state.metrics.visibleIDs(height: max(1, viewportHeight - bottomInset)),
            scrollProgress: layout == .all ? state.metrics.progress(height: viewportHeight) : nil,
            text: text, tint: tint, navigate: navigate)
    }
}

struct NotebookPracticeQuestionIndex: View {
    let displays: [NotebookPracticeQuestionDisplay]
    let currentID: String?
    let visibleIDs: Set<String>
    let scrollProgress: Double?
    let text: NotebookPracticeText
    let tint: Color
    let navigate: (String) -> Void
    @State private var outlinePresented = false
    @State private var hoveredID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hoveredIndex: Int? { displays.firstIndex { $0.id == hoveredID } }
    private func status(_ display: NotebookPracticeQuestionDisplay) -> String {
        display.selectedID == nil ? text.unansweredStatus : text.answeredStatus
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button { outlinePresented.toggle() } label: {
                Image(systemName: "list.bullet").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 25, alignment: .trailing).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(text.browseQuestions)
                .accessibilityIdentifier("practice.questionPicker").help(text.browseQuestions)
                .popover(isPresented: $outlinePresented, arrowEdge: .leading) {
                    NotebookPracticeQuestionPicker(displays: displays, currentID: currentID, text: text, tint: tint) { id in
                        navigate(id); outlinePresented = false
                    } dismiss: { outlinePresented = false }
                }
            if let scrollProgress {
                GeometryReader { geometry in
                    Capsule().fill(Color.secondary.opacity(0.15))
                        .overlay(alignment: .top) {
                            Capsule().fill(tint.opacity(0.7)).frame(height: max(2, geometry.size.height * scrollProgress))
                        }
                }.frame(width: 2).padding(.vertical, 6).padding(.trailing, 4)
                    .accessibilityLabel(text.allQuestions).accessibilityValue("\(Int(scrollProgress * 100))%")
                    .accessibilityIdentifier("practice.scrollProgress")
                    .allowsHitTesting(false)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                                questionMarker(display, index: index).id(display.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .trailing).padding(.vertical, 8)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hoveredID)
                    }.scrollIndicators(.hidden).accessibilityIdentifier("practice.questionRail")
                        .onChange(of: currentID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                        .onAppear { if let currentID { proxy.scrollTo(currentID, anchor: .center) } }
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("practice.questionIndex")
    }

    private func questionMarker(_ display: NotebookPracticeQuestionDisplay, index: Int) -> some View {
        let markerColor: Color = visibleIDs.contains(display.id) ? tint : Color.secondary.opacity(0.45)
        let markerWidth: CGFloat = MarkdownSectionEmphasis.width(index: index, hoveredIndex: hoveredIndex)
        let markerHeight: CGFloat = currentID == display.id ? 2.5 : 1.5
        return Button { navigate(display.id) } label: {
            HStack(spacing: 3) {
                Spacer(minLength: 0)
                if display.selectedID != nil {
                    Circle().fill(tint).frame(width: 4, height: 4)
                }
                Capsule().fill(markerColor).frame(width: markerWidth, height: markerHeight)
            }.frame(width: 32, height: 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .onHover { hoveredID = $0 ? display.id : (hoveredID == display.id ? nil : hoveredID) }
            .help(text.question(display.number) + " · " + status(display) + "\n" + display.prompt)
            .accessibilityLabel(text.question(display.number))
            .accessibilityValue(status(display))
            .accessibilityAddTraits(currentID == display.id ? .isSelected : [])
            .accessibilityIdentifier("practice.goToQuestion." + display.id)
    }

}

enum NotebookPracticeQuestionNavigation {
    static func matching(_ displays: [NotebookPracticeQuestionDisplay], search: String) -> [NotebookPracticeQuestionDisplay] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return displays }
        return displays.filter { String($0.number) == query || $0.prompt.localizedStandardContains(query) }
    }

    static func pickerHeight(count: Int) -> CGFloat { min(340, CGFloat(max(1, count)) * 64) }
}

struct NotebookPracticeQuestionPicker: View {
    let displays: [NotebookPracticeQuestionDisplay]
    let currentID: String?
    let text: NotebookPracticeText
    let tint: Color
    let navigate: (String) -> Void
    let dismiss: () -> Void
    @State private var search = ""
    @State private var hoveredID: String?
    private var visible: [NotebookPracticeQuestionDisplay] { NotebookPracticeQuestionNavigation.matching(displays, search: search) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(text.searchQuestions, text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("practice.searchQuestions")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel(text.clearSearch)
                }
            }.padding(9)
            Text(text.answered(displays.filter { $0.selectedID != nil }.count, of: displays.count))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.bottom, 7)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visible, id: \.id) { display in
                            Button { navigate(display.id) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: display.selectedID == nil ? "circle" : "checkmark.circle.fill")
                                        .font(.system(size: 11)).foregroundStyle(display.selectedID == nil ? Color.secondary : tint)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(text.question(display.number)).font(.system(size: 13, weight: .medium))
                                        NotebookPracticeQuestionPreview(text: display.prompt)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .frame(height: 30, alignment: .top).clipped().allowsHitTesting(false)
                                    }
                                    Spacer(minLength: 0)
                                    if currentID == display.id {
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                                    }
                                }.padding(.horizontal, 6).padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .modifier(SelectorRowBackground(highlighted: currentID == display.id || hoveredID == display.id))
                                .onHover { hoveredID = $0 ? display.id : nil }
                                .accessibilityValue(display.selectedID == nil ? text.unansweredStatus : text.answeredStatus)
                                .accessibilityAddTraits(currentID == display.id ? .isSelected : [])
                                .accessibilityIdentifier("practice.indexQuestion." + display.id).id(display.id)
                        }
                        if visible.isEmpty {
                            Text(text.noQuestionsFound).font(.callout).foregroundStyle(.secondary).padding(12)
                        }
                    }
                }.frame(height: NotebookPracticeQuestionNavigation.pickerHeight(count: visible.count))
                    .accessibilityIdentifier("practice.questionList")
                    .onAppear {
                        DispatchQueue.main.async { if let currentID { proxy.scrollTo(currentID, anchor: .center) } }
                    }
                    .onChange(of: search) { _, _ in if let first = visible.first { proxy.scrollTo(first.id, anchor: .top) } }
            }
        }.padding(5).frame(width: 350).background(Color(nsColor: .windowBackgroundColor))
            .onExitCommand(perform: dismiss)
    }
}

struct NotebookPracticeQuestionPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NotebookPracticePreviewTextView {
        let view = NotebookPracticePreviewTextView()
        view.isEditable = false; view.isSelectable = false; view.isRichText = true
        view.drawsBackground = false; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.maximumNumberOfLines = 2
        view.textContainer?.lineBreakMode = .byTruncatingTail
        view.isHorizontallyResizable = false; view.isVerticallyResizable = false
        return view
    }

    func updateNSView(_ view: NotebookPracticePreviewTextView, context: Context) {
        view.textStorage?.setAttributedString(MarkdownMathText.attributed(text, fontSize: 12))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NotebookPracticePreviewTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 280)
        view.textContainer?.containerSize = NSSize(width: width, height: 30)
        return CGSize(width: width, height: 30)
    }
}

final class NotebookPracticePreviewTextView: NSTextView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}
