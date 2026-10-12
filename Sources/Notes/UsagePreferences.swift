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
}

/// What Palladium's own chats would cost at public API prices. Counts only the
/// requests this app sent; the providers' other sessions are never read.
struct UsagePreferences: View {
    let workspace: SafeWorkspace
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    @AppStorage("notes.usagePeriod") private var period = "30"
    @AppStorage("notes.usageMetric") private var metric = "cost"
    @State private var records: [ProviderUsageRecord] = []
    @State private var rates = ProviderUsagePricing.builtIn
    @State private var pricesFetched: Date?
    @State private var refreshingPrices = false
    @State private var error: String?

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
                AIOptionSelector(title: text("Periodo", "Period"), symbol: "calendar", options: [
                    .init(id: "1", title: text("Últimas 24 horas", "Last 24 hours")),
                    .init(id: "7", title: text("Últimos 7 días", "Last 7 days")),
                    .init(id: "30", title: text("Últimos 30 días", "Last 30 days")),
                    .init(id: "all", title: text("Todo", "All time"))
                ], selection: $period).accessibilityIdentifier("usage.period")
                AIOptionSelector(title: text("Métrica", "Metric"), symbol: "chart.bar", options: [
                    .init(id: "cost", title: text("Coste", "Cost")), .init(id: "tokens", title: "Tokens")
                ], selection: $metric).accessibilityIdentifier("usage.metric")
                Spacer()
                Button(action: load) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13))
                        .foregroundStyle(.secondary).frame(width: 30, height: 30)
                        .modifier(ControlHoverBackground())
                }.buttonStyle(.plain)
                    .help(text("Actualizar uso", "Refresh usage"))
                    .accessibilityLabel(text("Actualizar uso", "Refresh usage"))
            }
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
                } else { chart(summary) }
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
        .tint(tint)
        .environment(\.locale, Locale(identifier: language))
        .onAppear(perform: load)
    }

    private func chart(_ summary: ProviderUsageSummary) -> some View {
        let hourly = period == "1"
        return Chart(summary.buckets) { bucket in
            BarMark(x: .value(text("Fecha", "Date"), bucket.start, unit: hourly ? .hour : .day),
                    y: .value(showsCost ? text("Coste", "Cost") : "Tokens", showsCost ? bucket.cost : Double(bucket.tokens)))
                .foregroundStyle(tint.opacity(0.85)).cornerRadius(2)
        }
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
        .frame(height: 130)
        .accessibilityIdentifier("usage.chart")
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
                }
            }.padding(16).modifier(NotebookInputSurface(radius: 14, borderOpacity: 0.22))
        }
    }

    private func modelRow(_ row: ProviderUsageSummary.Row, summary: ProviderUsageSummary) -> some View {
        let share = showsCost ? (summary.cost > 0 ? row.cost / summary.cost : 0) : Double(row.tokens) / Double(max(1, summary.tokens))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let provider = row.provider { ProviderLogo(provider: provider, size: 24) }
                else { Image(systemName: "clock.arrow.circlepath").frame(width: 24, height: 24).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.provider == nil ? text("Chat histórico (modelo desconocido)", "Historical chat (model unknown)") : row.model).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text((row.provider?.shortName ?? text("Proveedor desconocido", "Unknown provider")) + " · " + text("\(row.requests) peticiones", "\(row.requests) requests") + " · " + UsageFormat.tokens(row.tokens) + " tokens" + (row.estimated ? text(" · aproximado", " · approximate") : ""))
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
