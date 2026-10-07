import Foundation

/// Exact public invented content. The retention-permitted demo route accepts
/// only this fixture, never a flag attached to arbitrary/private transcript.
public enum SyntheticAIFixture {
    public static let version = "invented-ai-demo-v1"
    public static let note = "# Ejemplo sintético; no es doctrina jurídica\n\nEl concepto A utiliza tres pasos.\n"
    public static let segments: [MediaTranscriptSegment] = [
        .init(id: "s1", start: 0, end: 10, text: "Corrijo el concepto A: utiliza dos pasos, no tres."),
        .init(id: "s2", start: 10, end: 15, text: "No copiéis este inciso: mañana llueve."),
        .init(id: "s3", start: 15, end: 25, text: "El concepto B es importante para el examen. Significa ordenar los elementos por fecha."),
        .init(id: "s4", start: 25, end: 35, text: "Cuando cito a una persona que dijo 'no copiéis esto', estoy relatando una cita, no dando una orden nueva.")
    ]
    public static func matches(_ batch: AIBatch) -> Bool {
        batch.notebookID == "synthetic" && batch.expectedNote == note && batch.segments == segments && batch.priorSegments.isEmpty && batch.context == AIOutbox.relevantContext(note: note, selected: segments)
    }
}
