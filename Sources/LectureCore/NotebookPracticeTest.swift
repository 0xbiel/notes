import Foundation
import CryptoKit

public enum NotebookPracticeTestError: LocalizedError, Equatable, Sendable {
    case empty(String)
    case tooLong(String, limit: Int)
    case questionCount(Int)
    case optionCount(question: String, count: Int)
    case duplicateQuestionID(String)
    case duplicateOptionID(question: String, option: String)
    case invalidCorrectOption(question: String)
    case tooLarge(limit: Int)
    case unreadable(String)
    case incomplete(missing: Int)
    case unknownQuestion(String)
    case unknownOption(question: String, option: String)
    case alreadySubmitted
    case noAttempt

    public var errorDescription: String? { message(language: "es") }

    public func message(language: String) -> String {
        let en = language == "en"
        switch self {
        case .empty(let field): return en ? "The practice test has an empty \(field)." : "El test de práctica tiene \(field) vacío."
        case .tooLong(let field, let limit): return en ? "\(field) is longer than \(limit) characters." : "\(field) supera los \(limit) caracteres."
        case .questionCount(let count): return en ? "A practice test needs 1 to \(NotebookPracticeTest.questionLimit) questions, not \(count)." : "Un test de práctica necesita de 1 a \(NotebookPracticeTest.questionLimit) preguntas, no \(count)."
        case .optionCount(let question, let count): return en ? "Question \(question) needs 2 to \(NotebookPracticeTest.optionLimit) options, not \(count)." : "La pregunta \(question) necesita de 2 a \(NotebookPracticeTest.optionLimit) opciones, no \(count)."
        case .duplicateQuestionID(let id): return en ? "Question ID \(id) is repeated." : "El identificador de pregunta \(id) está repetido."
        case .duplicateOptionID(let question, let option): return en ? "Option ID \(option) is repeated in question \(question)." : "El identificador de opción \(option) está repetido en la pregunta \(question)."
        case .invalidCorrectOption(let question): return en ? "Question \(question) must name exactly one of its options as correct." : "La pregunta \(question) debe indicar exactamente una de sus opciones como correcta."
        case .tooLarge(let limit): return en ? "The practice test is larger than \(limit / 1024) KB." : "El test de práctica supera los \(limit / 1024) KB."
        case .unreadable(let detail): return en ? "The practice test could not be read: \(detail)" : "No se pudo leer el test de práctica: \(detail)"
        case .incomplete(let missing): return en ? "Answer \(missing) more question(s) before submitting." : "Responde \(missing) pregunta(s) más antes de enviar."
        case .unknownQuestion(let id): return en ? "Unknown question \(id)." : "Pregunta desconocida \(id)."
        case .unknownOption(let question, let option): return en ? "Question \(question) has no option \(option)." : "La pregunta \(question) no tiene la opción \(option)."
        case .alreadySubmitted: return en ? "This attempt was already submitted." : "Este intento ya se envió."
        case .noAttempt: return en ? "There is no attempt in progress." : "No hay ningún intento en curso."
        }
    }
}

public struct NotebookPracticeTest: Codable, Sendable, Equatable {
    public struct ReferenceImage: Codable, Sendable, Equatable {
        public var path: String
        public var alt: String
        public var caption: String
        public init(path: String, alt: String, caption: String = "") {
            self.path = path; self.alt = alt; self.caption = caption
        }
    }
    public struct Option: Codable, Sendable, Equatable {
        public var id: String
        public var text: String
        public var explanation: String
        public init(id: String, text: String, explanation: String) {
            self.id = id; self.text = text; self.explanation = explanation
        }
    }
    public struct Question: Codable, Sendable, Equatable {
        public var id: String
        public var prompt: String
        public var options: [Option]
        public var correctOptionID: String
        public var explanation: String
        public var images: [ReferenceImage]?
        public init(id: String, prompt: String, options: [Option], correctOptionID: String, explanation: String, images: [ReferenceImage]? = nil) {
            self.id = id; self.prompt = prompt; self.options = options
            self.correctOptionID = correctOptionID; self.explanation = explanation
            self.images = images
        }
        public var correctOption: Option? { options.first { $0.id == correctOptionID } }
        public func option(_ id: String) -> Option? { options.first { $0.id == id } }
    }

    public static let fileSuffix = ".quiz.json"
    public static let questionLimit = 100
    public static let optionLimit = 8
    public static let maximumBytes = 2 * 1024 * 1024
    static let idLimit = 64, titleLimit = 200, instructionsLimit = 2_000, textLimit = 4_000, optionTextLimit = 1_000

    public var title: String
    public var instructions: String
    public var questions: [Question]

    public init(title: String, instructions: String, questions: [Question]) {
        self.title = title; self.instructions = instructions; self.questions = questions
    }

    public static func isPracticeTest(_ path: String) -> Bool { path.hasSuffix(fileSuffix) }

    public func validate() throws {
        try Self.check(title, "title", limit: Self.titleLimit)
        try Self.check(instructions, "instructions", limit: Self.instructionsLimit)
        guard (1...Self.questionLimit).contains(questions.count) else { throw NotebookPracticeTestError.questionCount(questions.count) }
        var questionIDs = Set<String>()
        guard questions.reduce(0, { $0 + ($1.images?.count ?? 0) }) <= 24 else { throw NotebookPracticeTestError.tooLong("reference images", limit: 24) }
        for question in questions {
            guard (question.images?.count ?? 0) <= 4 else { throw NotebookPracticeTestError.tooLong("question images", limit: 4) }
            for image in question.images ?? [] {
                try Self.check(image.path, "image path", limit: 1_000)
                try Self.check(image.alt, "image description", limit: 1_000)
                guard image.caption.count <= 2_000 else { throw NotebookPracticeTestError.tooLong("image caption", limit: 2_000) }
                guard !image.path.hasPrefix("/"), !image.path.contains(":"), !image.path.contains("\\"),
                      !image.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw NotebookPracticeTestError.unreadable("Images must use relative notebook paths.")
                }
            }
            try Self.checkID(question.id, "question id")
            guard questionIDs.insert(question.id).inserted else { throw NotebookPracticeTestError.duplicateQuestionID(question.id) }
            try Self.check(question.prompt, "question \(question.id) prompt", limit: Self.textLimit)
            try Self.check(question.explanation, "question \(question.id) explanation", limit: Self.textLimit)
            guard (2...Self.optionLimit).contains(question.options.count) else {
                throw NotebookPracticeTestError.optionCount(question: question.id, count: question.options.count)
            }
            var optionIDs = Set<String>()
            for option in question.options {
                try Self.checkID(option.id, "option id")
                guard optionIDs.insert(option.id).inserted else { throw NotebookPracticeTestError.duplicateOptionID(question: question.id, option: option.id) }
                try Self.check(option.text, "option \(option.id) text of question \(question.id)", limit: Self.optionTextLimit)
                try Self.check(option.explanation, "option \(option.id) explanation of question \(question.id)", limit: Self.textLimit)
            }
            guard question.options.filter({ $0.id == question.correctOptionID }).count == 1 else {
                throw NotebookPracticeTestError.invalidCorrectOption(question: question.id)
            }
        }
    }

    public static func referenceImageURL(_ image: ReferenceImage, directory: URL, root: URL) throws -> URL {
        guard !image.path.hasPrefix("/"), !image.path.contains(":"), !image.path.contains("\\") else {
            throw NotebookPracticeTestError.unreadable("Images must use relative notebook paths.")
        }
        let url = directory.appendingPathComponent(image.path).standardizedFileURL.resolvingSymlinksInPath()
        let boundary = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(boundary), let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 20_000_000 else {
            throw NotebookPracticeTestError.unreadable("Reference image is missing or outside the notebook.")
        }
        return url
    }

    private static func check(_ value: String, _ field: String, limit: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NotebookPracticeTestError.empty(field) }
        guard value.count <= limit else { throw NotebookPracticeTestError.tooLong(field, limit: limit) }
    }

    private static func checkID(_ value: String, _ field: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw NotebookPracticeTestError.empty(field) }
        guard value.count <= idLimit else { throw NotebookPracticeTestError.tooLong(field, limit: idLimit) }
    }

    public static func decode(_ data: Data) throws -> NotebookPracticeTest {
        guard data.count <= maximumBytes else { throw NotebookPracticeTestError.tooLarge(limit: maximumBytes) }
        let test: NotebookPracticeTest
        do { test = try JSONDecoder().decode(NotebookPracticeTest.self, from: data) }
        catch { throw NotebookPracticeTestError.unreadable(error.localizedDescription) }
        try test.validate()
        return test
    }

    /// Validated, deterministic bytes suitable for a `.quiz.json` file.
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw NotebookPracticeTestError.tooLarge(limit: Self.maximumBytes) }
        return data
    }

    public static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public struct Loaded: Sendable, Equatable {
        public let test: NotebookPracticeTest
        public let digest: String
    }

    public static func load(workspace: SafeWorkspace, path: String) throws -> Loaded {
        guard isPracticeTest(path) else { throw NotebookPracticeTestError.unreadable(path) }
        let url = try workspace.fileURL(path)
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes {
            throw NotebookPracticeTestError.tooLarge(limit: maximumBytes)
        }
        let data = try workspace.readFile(path)
        return Loaded(test: try decode(data), digest: digest(of: data))
    }

    public func question(_ id: String) -> Question? { questions.first { $0.id == id } }

    /// Authored order is used when a stored order is not an exact permutation of the question's options.
    public func orderedOptions(of question: Question, order: [String]?) -> [Option] {
        guard let order, order.count == question.options.count, Set(order) == Set(question.options.map(\.id)) else { return question.options }
        return order.compactMap { question.option($0) }
    }

    /// Fresh option order for every question, always different from `previous` (or the authored order).
    public func shuffledOrders<G: RandomNumberGenerator>(previous: [String: [String]] = [:], using generator: inout G) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for question in questions {
            let ids = question.options.map(\.id)
            let reference = previous[question.id].flatMap { Set($0) == Set(ids) && $0.count == ids.count ? $0 : nil } ?? ids
            var order = ids.shuffled(using: &generator)
            if order == reference, order.count >= 2 { order = Array(order.dropFirst()) + [order[0]] }
            result[question.id] = order
        }
        return result
    }

    public func grade(_ answers: [String: String]) throws -> NotebookPracticeResult {
        var items: [NotebookPracticeResult.Item] = []
        var missing = 0
        for question in questions {
            guard let selected = answers[question.id] else { missing += 1; continue }
            guard question.option(selected) != nil else { throw NotebookPracticeTestError.unknownOption(question: question.id, option: selected) }
            items.append(.init(questionID: question.id, selectedOptionID: selected, correctOptionID: question.correctOptionID, isCorrect: selected == question.correctOptionID))
        }
        guard missing == 0 else { throw NotebookPracticeTestError.incomplete(missing: missing) }
        return NotebookPracticeResult(items: items)
    }
}

public struct NotebookPracticeResult: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let questionID: String
        public let selectedOptionID: String
        public let correctOptionID: String
        public let isCorrect: Bool
        public init(questionID: String, selectedOptionID: String, correctOptionID: String, isCorrect: Bool) {
            self.questionID = questionID; self.selectedOptionID = selectedOptionID
            self.correctOptionID = correctOptionID; self.isCorrect = isCorrect
        }
    }
    public let items: [Item]
    public init(items: [Item]) { self.items = items }
    public var total: Int { items.count }
    public var correct: Int { items.filter(\.isCorrect).count }
    public var percent: Int { total == 0 ? 0 : Int((Double(correct) / Double(total) * 100).rounded()) }
    public func item(_ questionID: String) -> Item? { items.first { $0.questionID == questionID } }
}

public struct NotebookPracticeAttempt: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var submittedAt: Date?
    public var optionOrder: [String: [String]]
    public var answers: [String: String]
    public var correct: Int?
    public var total: Int
    public init(id: String = UUID().uuidString, startedAt: Date = Date(), submittedAt: Date? = nil, optionOrder: [String: [String]], answers: [String: String] = [:], correct: Int? = nil, total: Int) {
        self.id = id; self.startedAt = startedAt; self.submittedAt = submittedAt
        self.optionOrder = optionOrder; self.answers = answers; self.correct = correct; self.total = total
    }
    public var isSubmitted: Bool { submittedAt != nil && correct != nil }
}

public struct NotebookPracticeHistory: Codable, Sendable, Equatable {
    public static let attemptLimit = 100
    public var version = 1
    public var path: String
    public var digest: String
    public var attempts: [NotebookPracticeAttempt]

    public init(path: String, digest: String, attempts: [NotebookPracticeAttempt] = []) {
        self.path = path; self.digest = digest; self.attempts = attempts
    }

    public var latest: NotebookPracticeAttempt? { attempts.last }
    public var submittedAttempts: [NotebookPracticeAttempt] { attempts.filter(\.isSubmitted) }

    public mutating func startAttempt<G: RandomNumberGenerator>(for test: NotebookPracticeTest, id: String = UUID().uuidString, now: Date = Date(), using generator: inout G) {
        let previous = attempts.last?.optionOrder ?? [:]
        if let last = attempts.last, !last.isSubmitted { attempts.removeLast() }
        attempts.append(NotebookPracticeAttempt(id: id, startedAt: now, optionOrder: test.shuffledOrders(previous: previous, using: &generator), total: test.questions.count))
        if attempts.count > Self.attemptLimit { attempts.removeFirst(attempts.count - Self.attemptLimit) }
    }

    public mutating func select(_ optionID: String, for questionID: String, in test: NotebookPracticeTest) throws {
        guard let last = attempts.indices.last else { throw NotebookPracticeTestError.noAttempt }
        guard !attempts[last].isSubmitted else { throw NotebookPracticeTestError.alreadySubmitted }
        guard let question = test.question(questionID) else { throw NotebookPracticeTestError.unknownQuestion(questionID) }
        guard question.option(optionID) != nil else { throw NotebookPracticeTestError.unknownOption(question: questionID, option: optionID) }
        attempts[last].answers[questionID] = optionID
    }

    @discardableResult
    public mutating func submit(test: NotebookPracticeTest, now: Date = Date()) throws -> NotebookPracticeResult {
        guard let last = attempts.indices.last else { throw NotebookPracticeTestError.noAttempt }
        guard !attempts[last].isSubmitted else { throw NotebookPracticeTestError.alreadySubmitted }
        let result = try test.grade(attempts[last].answers)
        attempts[last].submittedAt = now; attempts[last].correct = result.correct; attempts[last].total = result.total
        return result
    }

    /// Drops answers and orders that no longer match the test, so a stored attempt can never grade against the wrong key.
    func sanitized(for test: NotebookPracticeTest) -> NotebookPracticeHistory {
        var copy = self
        copy.attempts = attempts.compactMap { attempt in
            guard attempt.total == test.questions.count else { return nil }
            var cleaned = attempt
            cleaned.answers = attempt.answers.filter { test.question($0.key)?.option($0.value) != nil }
            cleaned.optionOrder = attempt.optionOrder.filter { entry in
                guard let question = test.question(entry.key) else { return false }
                return entry.value.count == question.options.count && Set(entry.value) == Set(question.options.map(\.id))
            }
            if cleaned.isSubmitted, cleaned.answers.count != test.questions.count { return nil }
            return cleaned
        }
        return copy
    }
}

public struct NotebookPracticeStore {
    public let workspace: SafeWorkspace
    public let path: String
    public let digest: String

    public init(workspace: SafeWorkspace, path: String, digest: String) {
        self.workspace = workspace; self.path = path; self.digest = digest
    }

    public var storagePath: String {
        "practice-tests/" + NotebookPracticeTest.digest(of: Data((path + "\u{0}" + digest).utf8)) + ".json"
    }

    public func load(for test: NotebookPracticeTest) -> NotebookPracticeHistory {
        let empty = NotebookPracticeHistory(path: path, digest: digest)
        let decoder = JSONDecoder()
        guard let data = try? workspace.readStorage(storagePath),
              let history = try? decoder.decode(NotebookPracticeHistory.self, from: data),
              history.path == path, history.digest == digest else { return empty }
        return history.sanitized(for: test)
    }

    public func save(_ history: NotebookPracticeHistory) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try workspace.writeStorage(storagePath, data: encoder.encode(history))
    }
}
