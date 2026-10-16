import SwiftUI
import LectureCore

/// T3-style native context control: provider usage and a dedicated compaction action.
struct NotebookContextMeter: View {
    @ObservedObject var assistant: NotebookAssistantController
    @ObservedObject var ai: AIController
    let notebook: Notebook
    var webEnabled = true
    @AppStorage("notes.language") private var language = "es"
    private var english: Bool { language == "en" }
    private var configuration: AIProviderConfiguration { ai.providerSettings.selected }
    private var native: Bool { NotesProviderTransport.supportsNativeNotebookSession(configuration.provider) }
    private var key: NotebookAssistantController.RunKey? {
        assistant.chat(notebook).map { .init(notebookID: notebook.id, chatID: $0.id) }
    }
    private var presented: Binding<Bool> {
        Binding(get: { key != nil && assistant.contextPanel == key }, set: { assistant.contextPanel = $0 ? key : nil })
    }
    var body: some View {
        let metrics = try? assistant.contextMetrics(notebook)
        let context = assistant.nativeContext(notebook, configuration: configuration, webEnabled: webEnabled)
        let ready = !native || assistant.hasNativeSession(notebook, configuration: configuration, webEnabled: webEnabled)
        let fraction: Double? = native
            ? context.flatMap { value in value.maxTokens.map { min(1, Double(value.usedTokens) / Double($0)) } }
            : metrics?.fraction
        let compacting = assistant.isCompacting(notebook)
        Button { presented.wrappedValue.toggle() } label: {
            ZStack {
                Circle().stroke(.secondary.opacity(0.2), lineWidth: 2.5)
                if compacting { ProgressView().controlSize(.mini) }
                else {
                    Circle().trim(from: 0, to: fraction ?? 0)
                        .stroke((fraction ?? 0) > 0.9 ? Color.orange : Color.secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }.frame(width: 17, height: 17).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain).disabled(key == nil)
        .help(english ? "Context window" : "Ventana de contexto")
        .accessibilityLabel(english ? "Context window" : "Ventana de contexto")
        .accessibilityIdentifier("notebook.contextMeter")
        .popover(isPresented: presented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(native ? (english ? "Context window" : "Ventana de contexto") : (english ? "Conversation history" : "Historial de conversación")).fontWeight(.medium)
                    Spacer()
                    if let fraction { Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary) }
                }
                if let fraction { ProgressView(value: fraction).accessibilityLabel(english ? "Context used" : "Contexto utilizado") }
                if native {
                    if let context {
                        HStack {
                            Text(english ? "Tokens" : "Tokens")
                            Spacer()
                            Text(context.maxTokens.map { "\(context.usedTokens.formatted()) / \($0.formatted())" } ?? context.usedTokens.formatted()).monospacedDigit()
                        }.foregroundStyle(.secondary)
                        Text(context.model).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        Text(ready ? (english ? "Waiting for the provider's context report." : "Esperando el informe de contexto del proveedor.") : (english ? "Send a message to start this provider session." : "Envía un mensaje para iniciar la sesión de este proveedor."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(english ? "The provider compacts this conversation automatically when needed." : "El proveedor compacta esta conversación automáticamente cuando es necesario.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let metrics {
                    HStack {
                        Text(english ? "History size" : "Tamaño del historial")
                        Spacer()
                        Text("\(metrics.bytes.formatted()) / \(metrics.capacity.formatted()) B").monospacedDigit()
                    }.foregroundStyle(.secondary)
                    Text(english ? "\(metrics.selected) of \(metrics.total) messages in context" : "\(metrics.selected) de \(metrics.total) mensajes en contexto").foregroundStyle(.secondary)
                    Text(english ? "Local history budget. Native compaction is not connected for this provider." : "Presupuesto local del historial. La compactación nativa no está conectada para este proveedor.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if compacting {
                    Label(english ? "Compacting context…" : "Compactando contexto…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                } else if let key, native ? assistant.hasNativeCompaction(notebook, configuration: configuration, webEnabled: webEnabled) : assistant.compactedContexts.contains(key) {
                    Label(english ? "Context compacted" : "Contexto compactado", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary).accessibilityIdentifier("notebook.contextCompacted")
                }
                Button { assistant.compactContext(notebook, configuration: configuration, webEnabled: webEnabled) } label: {
                    Label(english ? "Compact context" : "Compactar contexto", systemImage: "arrow.down.right.and.arrow.up.left").frame(maxWidth: .infinity)
                }
                .disabled(assistant.isRunning(notebook) || assistant.importingAttachments || !ready || (metrics?.total ?? 0) == 0)
                .accessibilityIdentifier("notebook.compactContext")
                if assistant.isRunning(notebook), !compacting {
                    Text(english ? "Available when the current reply finishes." : "Disponible cuando termine la respuesta actual.").foregroundStyle(.secondary)
                }
            }.font(.caption).padding(16).frame(width: 300)
        }
    }
}
