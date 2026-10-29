import SwiftUI
import LectureCore

struct NotebookPracticeText {
    let language: String
    private var en: Bool { language == "en" }
    var unavailable: String { en ? "Practice test unavailable" : "Test de práctica no disponible" }
    var practiceTest: String { en ? "Practice test" : "Test de práctica" }
    func question(_ number: Int) -> String { en ? "Question \(number)" : "Pregunta \(number)" }
    func answered(_ count: Int, of total: Int) -> String { en ? "\(count) of \(total) answered" : "\(count) de \(total) respondidas" }
    func remaining(_ count: Int) -> String { en ? "Answer \(count) more to submit" : "Responde \(count) más para enviar" }
    var submit: String { en ? "Submit answers" : "Enviar respuestas" }
    var retake: String { en ? "Retake test" : "Repetir test" }
    var view: String { en ? "Test view" : "Vista del test" }
    var flow: String { en ? "One at a time" : "Una a una" }
    var allQuestions: String { en ? "All questions" : "Todas las preguntas" }
    var back: String { en ? "Back" : "Anterior" }
    var next: String { en ? "Continue" : "Continuar" }
    func position(_ number: Int, of total: Int) -> String { en ? "Question \(number) of \(total)" : "Pregunta \(number) de \(total)" }
    var score: String { en ? "Score" : "Resultado" }
    func scoreLine(_ correct: Int, _ total: Int) -> String { en ? "\(correct) of \(total) correct" : "\(correct) de \(total) correctas" }
    func lastScore(_ correct: Int, _ total: Int) -> String { en ? "Last score: \(correct)/\(total)" : "Último resultado: \(correct)/\(total)" }
    var shuffled: String { en ? "Options are shuffled in every attempt." : "Las opciones se reordenan en cada intento." }
    var previousAttempts: String { en ? "Previous attempts" : "Intentos anteriores" }
    func attempt(_ number: Int) -> String { en ? "Attempt \(number)" : "Intento \(number)" }
    var correct: String { en ? "Correct" : "Correcta" }
    var incorrect: String { en ? "Incorrect" : "Incorrecta" }
    var yourAnswer: String { en ? "Your answer" : "Tu respuesta" }
    var correctAnswer: String { en ? "Correct answer" : "Respuesta correcta" }
    var whyRight: String { en ? "Why this is right" : "Por qué es correcta" }
    var whyWrong: String { en ? "Why your answer is wrong" : "Por qué tu respuesta es incorrecta" }
    var whyCorrectIsRight: String { en ? "Why the correct answer is right" : "Por qué la correcta es correcta" }
    var explanation: String { en ? "Explanation" : "Explicación" }
    var saveFailed: String { en ? "Progress could not be saved." : "No se pudo guardar el progreso." }
    var imageUnavailable: String { en ? "Reference image unavailable" : "Imagen de referencia no disponible" }
    var questions: String { en ? "Questions" : "Preguntas" }
    var browseQuestions: String { en ? "Browse questions" : "Explorar preguntas" }
    var answeredStatus: String { en ? "Answered" : "Respondida" }
    var unansweredStatus: String { en ? "Unanswered" : "Sin responder" }
    var searchQuestions: String { en ? "Search questions…" : "Buscar preguntas…" }
    var clearSearch: String { en ? "Clear search" : "Borrar búsqueda" }
    var noQuestionsFound: String { en ? "No questions found" : "No se encontraron preguntas" }
    func error(_ error: Error) -> String { (error as? NotebookPracticeTestError)?.message(language: language) ?? error.localizedDescription }
}

enum NotebookPracticeLayout: String, CaseIterable {
    case flow, all
}

struct NotebookPracticeLayoutSelector: View {
    @AppStorage("notes.practiceTest.layout") private var layout = NotebookPracticeLayout.flow
    @AppStorage("notes.language") private var language = "es"
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionAnimation
    var body: some View {
        let text = NotebookPracticeText(language: language)
        HStack(spacing: 2) {
            choice(text.flow, value: .flow)
            choice(text.allQuestions, value: .all)
        }.padding(4).background(.primary.opacity(0.045), in: Capsule())
            .accessibilityElement(children: .contain).accessibilityLabel(text.view)
            .accessibilityIdentifier("practice.layout")
    }
    private func choice(_ title: String, value: NotebookPracticeLayout) -> some View {
        Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { layout = value } } label: {
            Text(title).font(.system(size: 13, weight: layout == value ? .semibold : .regular))
                .foregroundStyle(layout == value ? .primary : .secondary).frame(minWidth: 90, minHeight: 30).padding(.horizontal, 8)
                .background {
                    if layout == value {
                        if #available(macOS 26.0, *), !reduceTransparency {
                            Capsule().fill(.clear).glassEffect(.regular.interactive(), in: .capsule)
                                .matchedGeometryEffect(id: "practice-mode", in: selectionAnimation)
                        } else {
                            Capsule().fill(Color(nsColor: .controlBackgroundColor)).overlay(Capsule().stroke(.separator.opacity(0.5)))
                        }
                    }
                }.contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityAddTraits(layout == value ? .isSelected : [])
            .accessibilityIdentifier("practice.layout.\(value.rawValue)")
    }
}

struct NotebookPracticeRandom: RandomNumberGenerator {
    var base: any RandomNumberGenerator
    mutating func next() -> UInt64 { base.next() }
}

struct NotebookPracticeQuestionDisplay: Equatable {
    struct Option: Equatable { let id: String; let text: String }
    struct Review: Equatable {
        let selectedID: String
        let correctID: String
        let selectedExplanation: String
        let correctExplanation: String
        let explanation: String
        var isCorrect: Bool { selectedID == correctID }
    }
    let id: String
    let number: Int
    let prompt: String
    let options: [Option]
    let selectedID: String?
    let review: Review?
    var images: [NotebookPracticeTest.ReferenceImage] = []
    var isWritten = false
    var writtenGrade: NotebookWrittenGrade? = nil
    var isSubmitted = false
}

@MainActor final class NotebookPracticeTestController: ObservableObject {
    let workspace: SafeWorkspace
    let path: String
    @Published private(set) var test: NotebookPracticeTest?
    @Published private(set) var history: NotebookPracticeHistory
    @Published private(set) var loadError: Error?
    @Published private(set) var saveFailed = false
    @Published private(set) var questionIndex = 0
    @Published private(set) var isGrading = false
    @Published private(set) var gradingError: String?
    private var store: NotebookPracticeStore?
    private var digest: String?
    private var generator: any RandomNumberGenerator
    private let now: () -> Date

    init(workspace: SafeWorkspace, path: String, generator: any RandomNumberGenerator = SystemRandomNumberGenerator(), now: @escaping () -> Date = Date.init) {
        self.workspace = workspace; self.path = path; self.generator = generator; self.now = now
        history = NotebookPracticeHistory(path: path, digest: "")
        reload()
    }

    func reload() {
        do {
            let loaded = try NotebookPracticeTest.load(workspace: workspace, path: path)
            guard loaded.digest != digest else { return }
            let store = NotebookPracticeStore(workspace: workspace, path: path, digest: loaded.digest)
            self.store = store; digest = loaded.digest; test = loaded.test; loadError = nil
            history = store.load(for: loaded.test)
            if history.latest == nil { startAttempt() }
            resumeFlow()
        } catch {
            store = nil; digest = nil; test = nil; loadError = error
        }
    }

    private func startAttempt() {
        guard let test else { return }
        var random = NotebookPracticeRandom(base: generator)
        history.startAttempt(for: test, now: now(), using: &random)
        generator = random.base
        questionIndex = 0
        persist()
    }

    private func persist() {
        guard let store else { return }
        do { try store.save(history); saveFailed = false } catch { saveFailed = true }
    }

    var attempt: NotebookPracticeAttempt? { history.latest }
    var isSubmitted: Bool { attempt?.isSubmitted == true }
    var answeredCount: Int { test.map { test in test.questions.filter { !(attempt?.answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count } ?? 0 }
    var totalCount: Int { test?.questions.count ?? 0 }
    var remainingCount: Int { totalCount - answeredCount }
    var canSubmit: Bool { test != nil && !isSubmitted && !isGrading && remainingCount == 0 }
    var currentDisplay: NotebookPracticeQuestionDisplay? { displays.indices.contains(questionIndex) ? displays[questionIndex] : nil }
    var isLastQuestion: Bool { totalCount > 0 && questionIndex == totalCount - 1 }
    var canContinue: Bool { !isLastQuestion && currentDisplay != nil }

    func goToQuestion(_ id: String) {
        guard let index = test?.questions.firstIndex(where: { $0.id == id }) else { return }
        questionIndex = index
    }

    func visibleDisplays(layout: NotebookPracticeLayout) -> [NotebookPracticeQuestionDisplay] {
        layout == .all ? displays : currentDisplay.map { [$0] } ?? []
    }

    func resumeFlow() {
        questionIndex = isSubmitted ? 0 : displays.firstIndex(where: { ($0.selectedID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? max(totalCount - 1, 0)
    }

    func previousQuestion() {
        guard questionIndex > 0 else { return }
        questionIndex -= 1
    }

    func nextQuestion() {
        guard canContinue else { return }
        questionIndex += 1
    }

    var result: NotebookPracticeResult? {
        guard let test, let attempt, attempt.isSubmitted else { return nil }
        return try? test.grade(attempt.answers, writtenGrades: attempt.writtenGrades ?? [:])
    }

    var earlierAttempts: [NotebookPracticeAttempt] {
        history.submittedAttempts.filter { $0.id != attempt?.id }
    }

    var displays: [NotebookPracticeQuestionDisplay] {
        guard let test, let attempt else { return [] }
        let result = self.result
        return test.questions.enumerated().map { index, question in
            let options = test.orderedOptions(of: question, order: attempt.optionOrder[question.id]).map { NotebookPracticeQuestionDisplay.Option(id: $0.id, text: $0.text) }
            let selected = attempt.answers[question.id]
            var review: NotebookPracticeQuestionDisplay.Review?
            if result != nil, let selected, let chosen = question.option(selected), let correct = question.correctOption {
                review = .init(selectedID: selected, correctID: correct.id, selectedExplanation: chosen.explanation, correctExplanation: correct.explanation, explanation: question.explanation)
            }
            return .init(id: question.id, number: index + 1, prompt: question.prompt, options: options, selectedID: selected, review: review, images: question.images ?? [], isWritten: question.isWritten, writtenGrade: attempt.writtenGrades?[question.id], isSubmitted: attempt.isSubmitted)
        }
    }

    func select(_ optionID: String, for questionID: String) {
        guard let test, !isSubmitted, !isGrading else { return }
        do { try history.select(optionID, for: questionID, in: test); persist() } catch {}
    }

    @discardableResult
    func submit() -> Bool {
        guard let test, canSubmit else { return false }
        do { try history.submit(test: test, now: now()); persist(); return true } catch { return false }
    }

    func submitWritten(using grade: NotebookPracticeGrader?) async -> Bool {
        guard let test, let attempt, canSubmit else { return false }
        guard test.questions.contains(where: \.isWritten) else { return submit() }
        guard let grade else {
            gradingError = "AI grading is unavailable. Open this quiz in a notebook with a configured model."
            return false
        }
        isGrading = true; gradingError = nil
        defer { isGrading = false }
        do {
            let response = try await grade(test, attempt.answers)
            try Task.checkCancellation()
            // A reload may replace the quiz while a provider request is in flight.
            guard self.attempt?.id == attempt.id, self.test == test else { return false }
            try history.submit(test: test, now: now(), writtenGrades: response.grades, gradingModel: response.model)
            persist()
            return true
        } catch {
            gradingError = error.localizedDescription
            return false
        }
    }

    func retake() {
        guard isSubmitted else { return }
        startAttempt()
    }
}

typealias NotebookPracticeGrader = @MainActor (NotebookPracticeTest, [String: String]) async throws -> (grades: [String: NotebookWrittenGrade], model: String)

struct NotebookPracticeTestView: View {
    let gradeAnswers: NotebookPracticeGrader?
    let imageDirectory: URL?
    let imageRoot: URL?
    let bottomInset: CGFloat
    let onFooterHeight: ((CGFloat) -> Void)?
    @StateObject private var controller: NotebookPracticeTestController
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    @AppStorage("notes.practiceTest.layout") private var layout = NotebookPracticeLayout.flow
    @State private var scrollState = NotebookPracticeScrollState()
    @State private var viewportHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(workspace: SafeWorkspace, path: String, imageRoot: URL? = nil, bottomInset: CGFloat = 0, onFooterHeight: ((CGFloat) -> Void)? = nil, gradeAnswers: NotebookPracticeGrader? = nil) {
        _controller = StateObject(wrappedValue: NotebookPracticeTestController(workspace: workspace, path: path))
        imageDirectory = try? workspace.fileURL(path).deletingLastPathComponent()
        self.imageRoot = imageRoot ?? workspace.courseRoot
        self.bottomInset = bottomInset; self.onFooterHeight = onFooterHeight; self.gradeAnswers = gradeAnswers
    }

    private var text: NotebookPracticeText { .init(language: language) }
    private var tint: Color { NotebookAccent.color(accent) }

    var body: some View {
        Group {
            if let test = controller.test {
                content(test)
            } else {
                ContentUnavailableView(text.unavailable, systemImage: "checklist", description: controller.loadError.map { Text(text.error($0)) })
                    .accessibilityIdentifier("practice.unavailable")
            }
        }
        .onAppear { controller.reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                controller.reload()
            }
        }
    }

    private func content(_ test: NotebookPracticeTest) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header(test).id("practice.top")
                    if let result = controller.result { scoreCard(result) }
                    if layout == .flow {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(text.position(controller.questionIndex + 1, of: controller.totalCount))
                                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                            ProgressView(value: Double(controller.questionIndex + 1), total: Double(controller.totalCount)).tint(tint)
                        }.accessibilityIdentifier("practice.flowProgress")
                    }
                    ForEach(controller.visibleDisplays(layout: layout), id: \.id) { display in
                        NotebookPracticeQuestionCard(display: display, text: text, tint: tint, imageDirectory: imageDirectory, imageRoot: imageRoot) { controller.select($0, for: display.id) }
                            .equatable()
                            .disabled(controller.isGrading)
                            .id(display.id)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: NotebookPracticeScrollPreference.self,
                                        value: .init(questions: [display.id: geometry.frame(in: .named("practice.scroll"))]))
                                }
                            }
                    }
                    if controller.isGrading { ProgressView(language == "en" ? "Grading answers…" : "Evaluando respuestas…") }
                    if let error = controller.gradingError { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                    if controller.saveFailed { Label(text.saveFailed, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                }
                .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                .padding(.leading, 24).padding(.trailing, 52).padding(.top, 28).padding(.bottom, 24 + bottomInset)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: NotebookPracticeScrollPreference.self,
                            value: .init(content: geometry.frame(in: .named("practice.scroll"))))
                    }
                }
            }
            .coordinateSpace(name: "practice.scroll")
            .onPreferenceChange(NotebookPracticeScrollPreference.self) { scrollState.update($0) }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .overlay(alignment: .trailing) {
                NotebookPracticeScrollIndex(state: scrollState, displays: controller.displays,
                    layout: layout, flowID: controller.currentDisplay?.id,
                    viewportHeight: viewportHeight, bottomInset: bottomInset, text: text, tint: tint) { id in
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            if layout == .flow { controller.goToQuestion(id); proxy.scrollTo("practice.top", anchor: .top) }
                            else { proxy.scrollTo(id, anchor: .top) }
                        }
                    }
                    .frame(width: 36, height: max(80, min(320, viewportHeight - bottomInset - 32)))
                    .padding(.trailing, 10).padding(.bottom, bottomInset)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer(proxy).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onFooterHeight?($0) }
            }
            .onChange(of: controller.attempt?.id) { _, _ in proxy.scrollTo("practice.top", anchor: .top) }
            .onChange(of: controller.questionIndex) { _, _ in if layout == .flow { proxy.scrollTo("practice.top", anchor: .top) } }
            .onChange(of: layout) { _, _ in
                if layout == .flow { controller.resumeFlow() }
                proxy.scrollTo("practice.top", anchor: .top)
            }
        }
        .accessibilityIdentifier("practice.test")
    }

    private func header(_ test: NotebookPracticeTest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text.practiceTest, systemImage: "checklist").font(.callout.weight(.medium)).foregroundStyle(tint)
            Text(test.title).font(.system(size: 26, weight: .semibold)).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            NotebookChatMarkdown(text: test.instructions, bodyFontSize: 14).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(test.questions.contains(where: \.isWritten) ? (language == "en" ? "Written answers are graded by your selected AI model" : "El modelo de IA seleccionado evalúa las respuestas escritas") : text.shuffled)
                if !controller.isSubmitted, let last = controller.earlierAttempts.last, let correct = last.correct {
                    Text(test.questions.contains(where: \.isWritten) ? (controller.test.flatMap { try? $0.grade(last.answers, writtenGrades: last.writtenGrades ?? [:]) }.map { scoreSummary($0) } ?? "") : text.lastScore(correct, last.total)).accessibilityIdentifier("practice.lastScore")
                }
            }.font(.callout).foregroundStyle(.tertiary)
        }
    }

    private func scoreSummary(_ result: NotebookPracticeResult) -> String {
        controller.test?.questions.contains(where: \.isWritten) == true
            ? String(format: "%.1f/10", result.score) : text.scoreLine(result.correct, result.total)
    }

    private func scoreCard(_ result: NotebookPracticeResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(controller.test?.questions.contains(where: \.isWritten) == true ? String(format: "%.1f/10", result.score) : "\(result.correct)/\(result.total)").font(.system(size: 34, weight: .semibold)).monospacedDigit()
                Text("\(result.percent)%").font(.title3).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: result.score, total: 10).tint(tint)
            if let model = controller.attempt?.gradingModel { Text(model).font(.callout).foregroundStyle(.secondary) }
            Text(scoreSummary(result)).foregroundStyle(.secondary)
            if !controller.earlierAttempts.isEmpty {
                Divider()
                Text(text.previousAttempts).font(.callout.weight(.medium))
                ForEach(Array(controller.earlierAttempts.enumerated()), id: \.element.id) { index, attempt in
                    HStack {
                        Text(text.attempt(index + 1))
                        Spacer()
                        Text(controller.test.flatMap { try? $0.grade(attempt.answers, writtenGrades: attempt.writtenGrades ?? [:]) }.map { scoreSummary($0) } ?? "").monospacedDigit()
                    }.font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.35)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text.score + ": " + scoreSummary(result))
        .accessibilityIdentifier("practice.score")
    }

    private func footer(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 12) {
            if layout == .flow {
                Button { controller.previousQuestion() } label: { Label(text.back, systemImage: "chevron.left") }
                    .buttonStyle(.bordered).controlSize(.large).disabled(controller.questionIndex == 0)
                    .accessibilityIdentifier("practice.back")
            }
            if controller.isSubmitted {
                Text(controller.result.map { scoreSummary($0) } ?? "").foregroundStyle(.secondary)
                Spacer()
                if layout == .flow && !controller.isLastQuestion {
                    Button { controller.nextQuestion() } label: { Label(text.next, systemImage: "chevron.right") }
                        .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("practice.continue")
                }
                Button { controller.retake() } label: { Label(text.retake, systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("practice.retake")
            } else {
                Text(layout == .flow || controller.canSubmit ? text.answered(controller.answeredCount, of: controller.totalCount) : text.remaining(controller.remainingCount))
                    .foregroundStyle(.secondary).monospacedDigit().accessibilityIdentifier("practice.progress")
                Spacer()
                if layout == .flow && !controller.isLastQuestion {
                    Button { controller.nextQuestion() } label: { Label(text.next, systemImage: "chevron.right") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!controller.canContinue)
                        .accessibilityIdentifier("practice.continue")
                } else {
                    Button {
                        Task {
                            if await controller.submitWritten(using: gradeAnswers) { controller.resumeFlow(); proxy.scrollTo("practice.top", anchor: .top) }
                        }
                    } label: { Label(controller.isGrading ? (language == "en" ? "Grading…" : "Evaluando…") : (controller.test?.questions.contains(where: \.isWritten) == true ? (language == "en" ? "Grade answers" : "Evaluar respuestas") : text.submit), systemImage: "checkmark.circle") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!controller.canSubmit).accessibilityIdentifier("practice.submit")
                }
            }
        }
        .tint(tint).padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: .infinity).background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct NotebookPracticeQuestionCard: View, Equatable {
    let display: NotebookPracticeQuestionDisplay
    let text: NotebookPracticeText
    let tint: Color
    var imageDirectory: URL? = nil
    var imageRoot: URL? = nil
    let onSelect: (String) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.display == rhs.display && lhs.text.language == rhs.text.language && lhs.tint == rhs.tint
            && lhs.imageDirectory == rhs.imageDirectory && lhs.imageRoot == rhs.imageRoot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text.question(display.number)).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            NotebookChatMarkdown(text: display.prompt, bodyFontSize: 16).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(display.images.enumerated()), id: \.offset) { index, image in
                NotebookPracticeReferenceImage(image: image, directory: imageDirectory, root: imageRoot, text: text)
                    .accessibilityIdentifier("practice.image.\(display.id).\(index)")
            }
            if display.isWritten {
                Text(text.language == "en" ? "Your answer" : "Tu respuesta").font(.callout.weight(.medium))
                TextEditor(text: Binding(get: { display.selectedID ?? "" }, set: { onSelect($0) }))
                    .font(.body).frame(minHeight: 150).padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(display.isSubmitted)
                    .accessibilityLabel(text.language == "en" ? "Written answer" : "Respuesta escrita")
                    .accessibilityIdentifier("practice.answer.\(display.id)")
                if let grade = display.writtenGrade {
                    Text(String(format: "%.1f/10", grade.score)).font(.title2.weight(.semibold))
                    section(text.language == "en" ? "Feedback" : "Comentarios", grade.feedback)
                    section(text.language == "en" ? "Mistakes and why" : "Errores y por qué", grade.mistakes)
                    section(text.language == "en" ? "Missing points and why they matter" : "Puntos que faltan y por qué importan", grade.omissions)
                }
            }
            VStack(spacing: 8) {
                ForEach(display.options, id: \.id) { option in row(option) }
            }
            if let review = display.review { reviewBlock(review) }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("practice.question.\(display.id)")
    }

    @ViewBuilder private func row(_ option: NotebookPracticeQuestionDisplay.Option) -> some View {
        let selected = display.selectedID == option.id
        if let review = display.review {
            let isCorrect = option.id == review.correctID, wrong = selected && !isCorrect
            rowBody(option, selected: selected, symbol: isCorrect ? "checkmark.circle.fill" : (wrong ? "xmark.circle.fill" : "circle"),
                    color: isCorrect ? .green : (wrong ? .red : .secondary), outline: isCorrect ? .green : (wrong ? .red : nil))
                .accessibilityElement(children: .combine)
                .accessibilityValue(isCorrect ? text.correctAnswer : (wrong ? text.yourAnswer + ", " + text.incorrect : ""))
                .accessibilityIdentifier("practice.option.\(display.id).\(option.id)")
        } else {
            Button { onSelect(option.id) } label: {
                rowBody(option, selected: selected, symbol: selected ? "largecircle.fill.circle" : "circle", color: selected ? tint : .secondary, outline: selected ? tint : nil)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("practice.option.\(display.id).\(option.id)")
        }
    }

    private func rowBody(_ option: NotebookPracticeQuestionDisplay.Option, selected: Bool, symbol: String, color: Color, outline: Color?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(color).frame(width: 22).padding(.top, 1)
            NotebookChatMarkdown(text: option.text, bodyFontSize: 16)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1).allowsHitTesting(false)
        }
        .padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
        .background((outline ?? .clear).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(outline?.opacity(0.7) ?? Color.primary.opacity(0.1), lineWidth: selected || outline != nil ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func reviewBlock(_ review: NotebookPracticeQuestionDisplay.Review) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(review.isCorrect ? text.correct : text.incorrect, systemImage: review.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(review.isCorrect ? Color.green : Color.red)
            if review.isCorrect {
                section(text.whyRight, review.selectedExplanation)
            } else {
                section(text.whyWrong, review.selectedExplanation)
                section(text.whyCorrectIsRight, review.correctExplanation)
            }
            section(text.explanation, review.explanation)
        }
        .padding(.top, 4).accessibilityElement(children: .contain)
        .accessibilityIdentifier("practice.review.\(display.id)")
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            NotebookChatMarkdown(text: body, bodyFontSize: 14).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct NotebookPracticeReferenceImage: View {
    let image: NotebookPracticeTest.ReferenceImage
    let directory: URL?
    let root: URL?
    let text: NotebookPracticeText
    @MainActor static func rendered(_ image: NotebookPracticeTest.ReferenceImage, directory: URL?, root: URL?) -> RenderedMarkdownImage? {
        guard let directory, let root, (try? NotebookPracticeTest.referenceImageURL(image, directory: directory, root: root)) != nil else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()<>%")
        guard let path = image.path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return MarkdownImageRenderer.render(source: "![Reference](\(path))", directory: directory, root: root, width: 740).first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let render = Self.rendered(image, directory: directory, root: root) {
                Image(nsImage: render.image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 360)
                    .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(image.alt)
            } else {
                Label(text.imageUnavailable, systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                Text(image.alt).font(.callout).foregroundStyle(.secondary)
            }
            if !image.caption.isEmpty { Text(image.caption).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}
