import SwiftUI
import Charts
import LectureCore

enum UsageFormat {
    static func cost(_ value: Double) -> String {
        if value > 0, value < 0.01 { return "<$0.01" }
        return "$" + String(format: "%.2f", locale: Locale(identifier: "en_US"), value)
    }
    /// 1,234 → 1.23K, as T3 Code abbreviates token counts.
    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        for (limit, suffix) in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")] where number >= limit {
            let scaled = number / limit
            let text = String(format: scaled >= 100 ? "%.0f" : scaled >= 10 ? "%.1f" : "%.2f", locale: Locale(identifier: "en_US"), scaled)
            return (text.contains(".") ? text.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) : text) + suffix
        }
        return String(value)
    }
    static func share(_ part: Double, of total: Double) -> String {
        guard total > 0, part > 0 else { return "0%" }
        let percent = part / total * 100
        return percent < 0.1 ? "<0.1%" : String(format: "%.1f%%", locale: Locale(identifier: "en_US"), percent)
    }
    /// 3d 4h, 4h 58m, 22m: the two largest units left until `date`.
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes >= 1_440 { return "\(minutes / 1_440)d \(minutes % 1_440 / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

/// The colors T3 Code gives each provider, so a series keeps its hue
/// whichever others are present; the provider list names every series.
enum UsageSeries {
    static let order = ["codexCLI", "claudeCode", "antigravity", "openCode", "unknown"]
    static func color(_ id: String) -> Color {
        switch id {
        case "codexCLI": .primary
        case "claudeCode": ProviderAccent.color("#D97757") ?? .orange
        case "antigravity": ProviderAccent.color("#8B7BE0") ?? .purple
        case "openCode": ProviderAccent.color("#5B9BD5") ?? .blue
        default: .secondary.opacity(0.6)
        }
    }
}

/// A group of tabs in one pill, as T3 Code's usage header has them.
struct UsageSegments: View {
    let title: String
    let options: [AIOption]
    @Binding var selection: String
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = selection == option.id
                Button { selection = option.id } label: {
                    Text(option.title).font(.callout).lineLimit(1).fixedSize()
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(.primary.opacity(selected ? 0.1 : hovered == option.id ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).onHover { hovered = $0 ? option.id : nil }
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(3).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityLabel(title).accessibilityValue(selection)
    }
}

/// What Palladium's own chats would cost at public API prices. Counts only the
/// requests this app sent; the providers' other sessions are never read.
struct UsagePreferences: View {
    let workspace: SafeWorkspace
    var readLimits: @Sendable (AIProviderConfiguration, LocalMediaStore) async -> ProviderLimits = ProviderLimitsProbe.read
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    @AppStorage("notes.usagePeriod") private var period = "30"
    @AppStorage("notes.usageMetric") private var metric = "cost"
    @State private var records: [ProviderUsageRecord] = []
    @State private var rates = ProviderUsagePricing.builtIn
    @State private var pricesFetched: Date?
    @State private var refreshingPrices = false
    @State private var error: String?
    @State var hovered: Date?
    @State private var limits: [ProviderLimits] = []
    @State private var loadingLimits = false
    private var showsLimits: Bool { metric == "limits" }
    private func color(_ id: String) -> Color { UsageSeries.color(id) }
    private func name(_ provider: NotesAIProvider?) -> String { provider?.shortName ?? text("Chats históricos", "Historical chats") }

    /// Asks every enabled subscription provider at once.
    private func loadLimits() async {
        guard !loadingLimits, let settings = try? AIProviderSettings.load(in: workspace) else { return }
        loadingLimits = true
        defer { loadingLimits = false }
        let store = LocalMediaStore(workspace: workspace), readLimits = readLimits
        let configurations = [NotesAIProvider.claudeCode, .codexCLI, .antigravity].map(settings.configuration(for:)).filter(\.accountSendingAllowed)
        limits = await withTaskGroup(of: (Int, ProviderLimits).self) { group in
            for (index, configuration) in configurations.enumerated() { group.addTask { (index, await readLimits(configuration, store)) } }
            var result: [(Int, ProviderLimits)] = []
            for await item in group { result.append(item) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func text(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private var tint: Color { NotebookAccent.color(accent) }
    private var showsCost: Bool { metric == "cost" }
    private var summary: ProviderUsageSummary { .init(records: records, rates: rates, days: Int(period)) }

    private func load() {
        records = ProviderUsageLog(workspace: workspace).records()
        rates = ProviderUsagePricing.rates(workspace)
        pricesFetched = ProviderUsagePricing.cached(workspace)?.fetched
    }

    private func refreshPrices() async {
        refreshingPrices = true; error = nil
        defer { refreshingPrices = false }
        do {
            try ProviderUsagePricing.save(try await ProviderUsagePricing.download(), workspace: workspace)
            load()
        } catch { self.error = text("No se pudieron actualizar los precios: ", "Could not update prices: ") + error.localizedDescription }
    }

    var body: some View {
        let summary = summary
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                UsageSegments(title: text("Métrica", "Metric"), options: [
                    .init(id: "cost", title: text("Coste", "Cost")), .init(id: "tokens", title: "Tokens"), .init(id: "limits", title: text("Límites", "Limits"))
                ], selection: $metric).accessibilityIdentifier("usage.metric")
                if !showsLimits {
                    UsageSegments(title: text("Periodo", "Period"), options: [
                        .init(id: "1", title: text("24 h", "Past 24h")), .init(id: "7", title: text("7 días", "7 days")), .init(id: "30", title: text("30 días", "30 days")),
                        .init(id: "90", title: text("90 días", "90 days")), .init(id: "all", title: text("Todo", "All"))
                    ], selection: $period).accessibilityIdentifier("usage.period")
                }
                Spacer()
                if loadingLimits && showsLimits { ProgressView().controlSize(.small) }
                Button { if showsLimits { Task { await loadLimits() } } else { load() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13))
                        .foregroundStyle(.secondary).frame(width: 30, height: 30)
                        .modifier(ControlHoverBackground())
                }.buttonStyle(.plain)
                    .help(text("Actualizar uso", "Refresh usage"))
                    .accessibilityLabel(text("Actualizar uso", "Refresh usage"))
            }
            if showsLimits { limitsView } else { history(summary) }
        }
        .tint(tint)
        .environment(\.locale, Locale(identifier: language))
        .onAppear(perform: load)
        .task(id: showsLimits) { if showsLimits { await loadLimits() } }
    }

    @ViewBuilder private func history(_ summary: ProviderUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(showsCost ? UsageFormat.cost(summary.cost) : UsageFormat.tokens(summary.tokens))
                    .font(.system(size: 34, weight: .semibold)).monospacedDigit()
                    .accessibilityIdentifier("usage.total")
                Text(text("\(summary.requests) peticiones", "\(summary.requests) requests") + (showsCost ? text(" · estimación a precio de API", " · API estimate") : " · tokens"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if summary.requests == 0 {
                Text(text("Sin actividad en este periodo.", "No activity in this window."))
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
            } else {
                chart(summary)
                VStack(spacing: 10) { ForEach(summary.providers) { providerRow($0, summary: summary) } }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(NotebookInputSurface(radius: 14, borderOpacity: 0.22))
        if summary.requests > 0 {
            tokenTypes(summary)
            VStack(alignment: .leading, spacing: 10) {
                Text(text("Desglose", "Breakdown")).font(.headline)
                VStack(spacing: 0) {
                    ForEach(Array(summary.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().opacity(0.35) }
                        modelRow(row, summary: summary)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 4).modifier(NotebookInputSurface(radius: 14, borderOpacity: 0.22))
            }
        }
        notes(summary)
    }

    private func value(_ part: ProviderUsageSummary.Part) -> String { showsCost ? UsageFormat.cost(part.cost) : UsageFormat.tokens(part.tokens) }

    /// The legend and the table of the chart at once.
    private func providerTotalDetail(_ total: ProviderUsageSummary.ProviderTotal, summary: ProviderUsageSummary) -> String {
        if showsCost {
            let share: String = UsageFormat.share(total.cost, of: summary.cost)
            return share + " · " + UsageFormat.tokens(total.tokens) + " tokens"
        }
        let share: String = UsageFormat.share(Double(total.tokens), of: Double(summary.tokens))
        return share + " · " + UsageFormat.cost(total.cost)
    }

    private func providerRow(_ total: ProviderUsageSummary.ProviderTotal, summary: ProviderUsageSummary) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(total.id)).frame(width: 8, height: 8)
            if let provider = total.provider { ProviderLogo(provider: provider, size: 16) }
            Text(name(total.provider)).font(.callout)
            Text(text("\(total.requests) peticiones", "\(total.requests) requests")).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(providerTotalDetail(total, summary: summary))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(value(.init(cost: total.cost, tokens: total.tokens))).font(.callout.weight(.medium)).monospacedDigit().frame(minWidth: 62, alignment: .trailing)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("usage.provider." + total.id)
    }

    /// Every provider at the hovered day or hour, then the total.
    private func tooltip(_ bucket: ProviderUsageSummary.Bucket, hourly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bucket.start, format: hourly ? .dateTime.month(.abbreviated).day().hour() : .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.caption).foregroundStyle(.secondary)
            ForEach(UsageSeries.order.filter { bucket.providers[$0] != nil }, id: \.self) { id in
                HStack(spacing: 6) {
                    Capsule().fill(color(id)).frame(width: 10, height: 3)
                    Text(name(NotesAIProvider(rawValue: id))).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 14)
                    Text(value(bucket.providers[id]!)).font(.caption.weight(.medium)).monospacedDigit()
                }
            }
            Divider().opacity(0.4)
            HStack {
                Text("Total").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 14)
                Text(value(.init(cost: bucket.cost, tokens: bucket.tokens))).font(.caption.weight(.semibold)).monospacedDigit()
            }
            if showsCost { Text(UsageFormat.tokens(bucket.tokens) + " tokens").font(.caption2).foregroundStyle(.tertiary) }
        }.padding(10).frame(width: 190)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.14)))
            .accessibilityIdentifier("usage.chart.tooltip")
    }

    private func chart(_ summary: ProviderUsageSummary) -> some View {
        let hourly = period == "1", name = text("Fecha", "Date"), measure = showsCost ? text("Coste", "Cost") : "Tokens"
        let selected = hovered.flatMap { date in summary.buckets.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) } }
        func amount(_ bucket: ProviderUsageSummary.Bucket, _ id: String) -> Double { showsCost ? bucket.providers[id]?.cost ?? 0 : Double(bucket.providers[id]?.tokens ?? 0) }
        // The largest series is drawn first so the smaller ones stay visible over it.
        let series = UsageSeries.order.filter { id in summary.providers.contains { $0.id == id } }
        return Chart {
            ForEach(series, id: \.self) { id in
                ForEach(summary.buckets) { bucket in
                    AreaMark(x: .value(name, bucket.start), y: .value(measure, amount(bucket, id)), series: .value("Provider", id), stacking: .unstacked)
                        .foregroundStyle(color(id).opacity(0.12)).interpolationMethod(.monotone)
                    LineMark(x: .value(name, bucket.start), y: .value(measure, amount(bucket, id)), series: .value("Provider", id))
                        .foregroundStyle(color(id)).lineStyle(.init(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).interpolationMethod(.monotone)
                }
            }
            if let selected {
                RuleMark(x: .value(name, selected.start))
                    .foregroundStyle(.primary.opacity(0.18)).lineStyle(.init(lineWidth: 1))
                    .annotation(position: selected.start > summary.buckets[summary.buckets.count / 2].start ? .leading : .trailing, alignment: .top, spacing: 10, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        if selected.tokens > 0 { tooltip(selected, hourly: hourly) }
                    }
                ForEach(series.filter { selected.providers[$0] != nil }, id: \.self) { id in
                    PointMark(x: .value(name, selected.start), y: .value(measure, amount(selected, id)))
                        .foregroundStyle(color(id)).symbolSize(36)
                }
            }
        }
        .chartXSelection(value: $hovered)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(showsCost ? UsageFormat.cost(amount) : UsageFormat.tokens(Int(amount))).font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: hourly ? .dateTime.hour() : .dateTime.month(.abbreviated).day()).font(.caption2)
            }
        }
        .frame(height: 180)
        .accessibilityIdentifier("usage.chart")
    }

    private func label(_ window: ProviderLimitWindow) -> String {
        let kind: String
        switch window.kind {
        case .session: kind = text("Sesión", "Session")
        case .weekly: kind = text("Semanal", "Weekly")
        case .monthly: kind = text("Mensual", "Monthly")
        case .other: kind = text("Cuota", "Quota")
        }
        return window.scope.map { $0 + " · " + kind } ?? kind
    }

    /// What is left of each allowance, and when it renews.
    @ViewBuilder private var limitsView: some View {
        if limits.isEmpty {
            Text(loadingLimits ? text("Consultando los límites de tus cuentas…", "Reading your accounts' limits…") : text("No hay proveedores de suscripción activados.", "No subscription provider is enabled."))
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
        }
        ForEach(limits) { provider in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProviderLogo(provider: provider.provider, size: 18)
                    Text(provider.name).font(.headline)
                    if let plan = provider.plan, !plan.isEmpty { Text(plan.capitalized).font(.caption).foregroundStyle(.secondary) }
                }
                if provider.windows.isEmpty {
                    Text(NotebookAssistantText.display(provider.message ?? "", language: language)).font(.callout).foregroundStyle(.secondary)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(NotebookInputSurface(radius: 14, borderOpacity: 0.22))
                }
                ForEach(provider.windows) { window in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(window)).font(.callout)
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text("\(Int(window.leftPercent.rounded()))%").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                                Text(text("restante", "left")).font(.callout).foregroundStyle(.secondary)
                            }
                        }.frame(width: 170, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 6) {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.primary.opacity(0.07))
                                    Capsule().fill(color(provider.id)).frame(width: max(window.leftPercent > 0 ? 4 : 0, geometry.size.width * CGFloat(window.leftPercent / 100)))
                                }
                            }.frame(height: 8).accessibilityHidden(true)
                            if let reset = window.resetsAt {
                                Label(text("Se renueva en ", "Resets in ") + UsageFormat.countdown(to: reset), systemImage: "arrow.clockwise")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    .help(reset.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute().locale(Locale(identifier: language))))
                            }
                        }
                    }.padding(16).modifier(NotebookInputSurface(radius: 14, borderOpacity: 0.22))
                        .accessibilityElement(children: .combine).accessibilityIdentifier("usage.limit." + provider.id + "." + window.id)
                }
            }
        }
        Text(text("Son los límites de tu cuenta, tal como los publica cada proveedor: incluyen el uso fuera de Palladium. Claude Code y Codex responden desde su propia CLI sin enviar ninguna petición al modelo; Antigravity se consulta con la sesión de Google de su perfil.", "These are your account's limits as each provider reports them, so they include usage outside Palladium. Claude Code and Codex answer from their own CLI without a model request; Antigravity is asked with its profile's Google session."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func tokenTypes(_ summary: ProviderUsageSummary) -> some View {
        let parts: [(String, Int, Double)] = [
            (text("Entrada sin caché", "Uncached input"), summary.input, 1),
            (text("Entrada en caché", "Cached input"), summary.cachedInput, 0.6),
            (text("Escritura de caché", "Cache write"), summary.cacheWrite, 0.38),
            (text("Salida", "Output"), summary.output, 0.2)
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text(text("Tokens por tipo", "Tokens by type")).font(.headline)
            VStack(alignment: .leading, spacing: 14) {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(parts.filter { $0.1 > 0 }, id: \.0) { part in
                            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(part.2))
                                .frame(width: max(2, (geometry.size.width - 6) * CGFloat(part.1) / CGFloat(max(1, summary.tokens))))
                        }
                    }
                }.frame(height: 8).clipShape(Capsule()).accessibilityHidden(true)
                VStack(spacing: 8) {
                    ForEach(parts, id: \.0) { part in
                        HStack(spacing: 8) {
                            Circle().fill(tint.opacity(part.2)).frame(width: 8, height: 8)
                            Text(part.0).font(.callout)
                            Spacer(minLength: 8)
                            Text(UsageFormat.share(Double(part.1), of: Double(summary.tokens))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            Text(UsageFormat.tokens(part.1)).font(.callout).monospacedDigit().frame(minWidth: 62, alignment: .trailing)
                        }
                    }
                    Divider().opacity(0.35)
                    HStack {
                        Text(text("Acierto de caché", "Cache hit")).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Text(UsageFormat.share(summary.cacheHit, of: 1)).font(.callout).monospacedDigit()
                    }
                    if summary.cacheSavings > 0 {
                        HStack {
                            Text(text("Ahorro por caché", "Cache savings")).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Text(UsageFormat.cost(summary.cacheSavings)).font(.callout).monospacedDigit()
                        }
                    }
                }
            }.padding(16).modifier(NotebookInputSurface(radius: 14, borderOpacity: 0.22))
        }
    }

    private func modelRowDetail(_ row: ProviderUsageSummary.Row) -> String {
        var parts: [String] = [row.provider?.shortName ?? text("Proveedor desconocido", "Unknown provider")]
        parts.append(text("\(row.requests) peticiones", "\(row.requests) requests"))
        parts.append(UsageFormat.tokens(row.tokens) + " tokens")
        if row.estimated { parts.append(text("aproximado", "approximate")) }
        return parts.joined(separator: " · ")
    }

    private func modelRow(_ row: ProviderUsageSummary.Row, summary: ProviderUsageSummary) -> some View {
        let share = showsCost ? (summary.cost > 0 ? row.cost / summary.cost : 0) : Double(row.tokens) / Double(max(1, summary.tokens))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let provider = row.provider { ProviderLogo(provider: provider, size: 24) }
                else { Image(systemName: "clock.arrow.circlepath").frame(width: 24, height: 24).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.provider == nil ? text("Chat histórico (modelo desconocido)", "Historical chat (model unknown)") : row.model).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(modelRowDetail(row))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    if showsCost && row.unpriced && row.cost == 0 {
                        Text(text("Sin precio", "Unpriced")).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(showsCost ? UsageFormat.cost(row.cost) : UsageFormat.tokens(row.tokens)).font(.callout.weight(.medium)).monospacedDigit()
                    }
                    Text(UsageFormat.share(share, of: 1)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    Capsule().fill(tint.opacity(0.85)).frame(width: geometry.size.width * CGFloat(min(max(share, 0), 1)))
                }
            }.frame(height: 4).accessibilityHidden(true)
        }.padding(.vertical, 12).accessibilityElement(children: .combine).accessibilityIdentifier("usage.model." + row.model)
    }

    @ViewBuilder private func notes(_ summary: ProviderUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if summary.unpricedTokens > 0 {
                Label(text("\(UsageFormat.tokens(summary.unpricedTokens)) tokens son de modelos sin precio conocido y no se incluyen en el coste.", "\(UsageFormat.tokens(summary.unpricedTokens)) tokens come from models with no known price and are left out of the cost."), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if summary.estimatedTokens > 0 {
                Label(text("Los tokens sin datos del proveedor se aproximan por la longitud del texto. Los chats antiguos solo incluyen el texto guardado, no el contexto, las herramientas ni las imágenes; se desconoce su modelo y no se estima su coste.", "Tokens without provider data are approximated from text length. Older chats include only saved text, not context, tools or images; their model is unknown and their cost is not estimated."), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(text("Solo cuenta los chats de Palladium: no se lee el resto de tu uso de Claude Code, Codex o Antigravity. Es lo que costarían esos tokens a precio público de API; con una suscripción no se te cobra este importe.", "Counts only Palladium's chats: the rest of your Claude Code, Codex or Antigravity usage is never read. It is what these tokens would cost at public API prices; a subscription is not billed this amount."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { Task { await refreshPrices() } } label: {
                    Label(text("Actualizar precios", "Update prices"), systemImage: "arrow.down.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).frame(height: 34)
                        .modifier(ControlHoverBackground())
                }.buttonStyle(.plain).disabled(refreshingPrices)
                    .help(text("Descarga la lista pública de precios de LiteLLM, la misma que usa T3 Code.", "Downloads LiteLLM's public price list, the one T3 Code uses."))
                    .accessibilityIdentifier("usage.prices.refresh")
                if refreshingPrices { ProgressView().controlSize(.small) }
                Text(pricesFetched.map { text("Precios del ", "Prices from ") + $0.formatted(.dateTime.year().month(.abbreviated).day().locale(Locale(identifier: language))) } ?? text("Precios incluidos en la app", "Prices built into the app"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}
