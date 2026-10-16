import SwiftUI
import LectureCore

enum NotebookAtlasPalette {
    /// System colours, so each region reads well in light and dark appearance alike.
    static let colours: [NSColor] = [.systemPurple, .systemTeal, .systemOrange, .systemPink, .systemGreen, .systemBlue, .systemYellow, .systemIndigo, .systemBrown, .systemMint]
    static func nsColor(_ index: Int) -> NSColor { colours[index % colours.count] }
    static func color(_ index: Int) -> Color { Color(nsColor: nsColor(index)) }
}

/// The library seen as a graph of points: each notebook a region of one colour, its subjects clusters inside it.
struct NotebookAtlasView: View {
    @ObservedObject var model: Workbench
    @ObservedObject var maps: NotebookMapController
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    @AppStorage("notes.mapAutoUpdate") private var automatic = true
    @State private var hidden: Set<Int> = []
    @State private var focus: Int?
    @State private var labels = false
    @State private var hovered: (index: Int, at: CGPoint)?
    @State private var confirmingRemoval = false
    /// `focus` opens the atlas on one region, with its subjects named.
    init(model: Workbench, maps: NotebookMapController, focus: Int? = nil) {
        self.model = model; self.maps = maps
        _focus = State(initialValue: focus)
    }
    private func t(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private var atlas: NotebookAtlas? { maps.atlas.flatMap { $0.points.isEmpty ? nil : $0 } }

    var body: some View {
        Group {
            if let atlas { field(atlas) }
            else { VStack(spacing: 0) { plainBar; Divider().opacity(0.4); placeholder.frame(maxWidth: .infinity, maxHeight: .infinity) } }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("notebook.map")
        .task { maps.load(); model.refreshMap() }
        .onChange(of: maps.atlas?.regions.count) { old, _ in if old != nil { hidden = []; focus = nil } }
        .onExitCommand { if focus != nil { focus = nil } else { model.showMap = false } }
        .confirmationDialog(t("¿Eliminar el modelo local?", "Remove the local model?"), isPresented: $confirmingRemoval) {
            Button(t("Eliminar", "Remove"), role: .destructive) { maps.removeModel() }
            Button(t("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(t("Se liberan unos 880 MB. El atlas ya hecho se conserva, pero deja de actualizarse hasta que lo descargues de nuevo.",
                   "This frees about 880 MB. The atlas already made is kept, but stops updating until you download it again."))
        }
    }

    private var status: String {
        if let progress = maps.working { return t("Leyendo \(progress.notebook) · \(progress.done) de \(progress.total)", "Reading \(progress.notebook) · \(progress.done) of \(progress.total)") }
        if maps.reading { return t("Comprobando cambios…", "Checking for changes…") }
        return ""
    }

    // MARK: The field

    private func field(_ atlas: NotebookAtlas) -> some View {
        ZStack(alignment: .topLeading) {
            NotebookAtlasCanvas(atlas: atlas, hidden: hidden, focus: focus, labels: labels,
                                hover: { index, point in hovered = index.map { ($0, point) } },
                                open: { model.openMapItem(atlas.points[$0].item) })
            .accessibilityHidden(true)
            WindowDragRegion().frame(height: 30).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Circle().fill(maps.reading ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text("ATLAS").tracking(1.5)
                    Text("·").foregroundStyle(.tertiary)
                    Text(t("\(atlas.regions.count) regiones · \(atlas.points.count) lugares", "\(atlas.regions.count) regions · \(atlas.points.count) places")).foregroundStyle(.secondary)
                }.font(.system(size: 12, design: .monospaced)).accessibilityIdentifier("notebook.map.status")
                regions(atlas)
            }.padding(.leading, 18).padding(.top, 38)
            VStack { Spacer(); bottom }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            VStack(alignment: .trailing, spacing: 8) { controls(atlas) }
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 16).padding(.top, 36)
            if let hovered, atlas.points.indices.contains(hovered.index) { tooltip(atlas, atlas.points[hovered.index], at: hovered.at) }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func regions(_ atlas: NotebookAtlas) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t("REGIONES", "REGIONS")).font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(atlas.regions.indices, id: \.self) { index in row(atlas.regions[index], index: index) }
                }
            }.frame(maxHeight: 420).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12).padding(.horizontal, 4).frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
    }
    private func row(_ region: NotebookAtlas.Region, index: Int) -> some View {
        let shown = !hidden.contains(index)
        return HStack(alignment: .top, spacing: 4) {
            Button { if shown { hidden.insert(index); if focus == index { focus = nil } } else { hidden.remove(index) } } label: {
                RoundedRectangle(cornerRadius: 2).fill(shown ? NotebookAtlasPalette.color(index) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(NotebookAtlasPalette.color(index), lineWidth: 1))
                    .frame(width: 9, height: 9).padding(.top, 3)
                    .frame(width: 22, height: 30, alignment: .top).contentShape(Rectangle())
            }.buttonStyle(.plain).help(shown ? t("Ocultar", "Hide") : t("Mostrar", "Show"))
                .accessibilityLabel((shown ? t("Ocultar ", "Hide ") : t("Mostrar ", "Show ")) + region.title)
            Button { focus = focus == index ? nil : index; if focus != nil { hidden.remove(index) } } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(region.title.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                        if !region.subtitle.isEmpty { Text(region.subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 6)
                    Text(String(format: "%02d", region.count)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("notebook.map.region.\(index)")
                .accessibilityValue(focus == index ? t("Enfocada", "Focused") : "")
        }
        .opacity(shown ? 1 : 0.45)
        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 6)
        .background(focus == index ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func controls(_ atlas: NotebookAtlas) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                chip(t("Etiquetas", "Labels"), on: labels) { labels.toggle() }
                chip(t("Todo", "All"), on: hidden.isEmpty) { hidden = [] }
                chip(t("Nada", "None"), on: hidden.count == atlas.regions.count) { hidden = Set(atlas.regions.indices); focus = nil }
            }
            HStack(spacing: 6) {
                if maps.installed {
                    icon("arrow.clockwise", t("Leer las notas de nuevo", "Read the notes again")) { model.refreshMap() }.disabled(maps.reading)
                    Menu {
                        Toggle(t("Actualizar al cambiar las notas", "Update when notes change"), isOn: $automatic)
                        Divider()
                        Button(t("Eliminar el modelo local…", "Remove the local model…")) { confirmingRemoval = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 30, height: 26).contentShape(Rectangle()) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel(t("Opciones del atlas", "Atlas options")).accessibilityIdentifier("notebook.map.options")
                }
                icon("xmark", t("Cerrar el atlas", "Close the atlas")) { model.showMap = false }.accessibilityIdentifier("notebook.map.close")
            }
        }
    }
    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(on ? Color(nsColor: .textBackgroundColor) : .primary)
                .padding(.horizontal, 10).frame(height: 26)
                .background(on ? AnyShapeStyle(Color.primary.opacity(0.85)) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(on ? 0 : 0.12)))
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
    private func icon(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 30, height: 26)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private var bottom: some View {
        HStack(spacing: 10) {
            if maps.reading { ProgressView().controlSize(.small) }
            if let error = maps.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1) }
            else if !status.isEmpty { Text(status) }
            Spacer()
            Text(t("ARRASTRA · MOVER — RUEDA · ZOOM — CLIC · ABRIR", "DRAG · MOVE — SCROLL · ZOOM — CLICK · OPEN")).tracking(1).foregroundStyle(.tertiary)
        }
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        .padding(.horizontal, 18).padding(.bottom, 14)
    }
    private func tooltip(_ atlas: NotebookAtlas, _ point: NotebookAtlas.Point, at: CGPoint) -> some View {
        let item = point.item
        var place = item.file
        if let heading = item.heading { place += " › " + NotebookMapBuilder.clean(heading) }
        if let page = item.page { place += t(" · página ", " · page ") + String(page) }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(NotebookAtlasPalette.color(point.region)).frame(width: 6, height: 6)
                Text(NotebookMapBuilder.clean(item.title)).font(.system(size: 12, weight: .medium)).lineLimit(2)
            }
            Text(place).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            if atlas.topics.indices.contains(point.topic) {
                Text(atlas.regions[point.region].title + " · " + atlas.topics[point.topic].title).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1)))
        .fixedSize().offset(x: at.x + 14, y: at.y + 14).allowsHitTesting(false)
    }

    // MARK: Before there is an atlas

    private var plainBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Atlas").font(.system(size: 13, weight: .medium))
                Text(status.isEmpty ? t("Toda tu biblioteca", "Your whole library") : status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("notebook.map.status")
            }
            if maps.reading { ProgressView().controlSize(.small) }
            Spacer()
            Button { model.showMap = false } label: { Image(systemName: "xmark").frame(width: 34, height: 34).contentShape(Rectangle()).modifier(ControlHoverBackground()) }
                .buttonStyle(.plain).help(t("Cerrar el atlas", "Close the atlas")).accessibilityLabel(t("Cerrar el atlas", "Close the atlas")).accessibilityIdentifier("notebook.map.close")
        }
        .padding(.horizontal, 18).frame(height: 58).background(WindowDragRegion())
    }
    @ViewBuilder private var placeholder: some View {
        if !NotebookEmbeddingRuntime.supported {
            ContentUnavailableView(t("No disponible en este Mac", "Not available on this Mac"), systemImage: "circle.hexagongrid",
                                   description: Text(t("El atlas usa un modelo local que necesita Apple silicon.", "The atlas uses a local model that needs Apple silicon.")))
        } else if !maps.installed { setup }
        else if let error = maps.error {
            VStack(spacing: 12) {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: 480)
                Button(t("Reintentar", "Try again")) { model.refreshMap() }
            }
        } else if maps.reading {
            VStack(spacing: 12) {
                if let progress = maps.working { ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))).frame(width: 240) }
                else { ProgressView() }
                Text(t("Leyendo tus cuadernos en este Mac…", "Reading your notebooks on this Mac…")).font(.callout).foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView(t("Todavía no hay nada que relacionar", "Nothing to connect yet"), systemImage: "circle.hexagongrid",
                                   description: Text(t("Añade notas, PDF o imágenes a tus cuadernos y el atlas se formará solo.", "Add notes, PDFs or pictures to your notebooks and the atlas will form by itself.")))
        }
    }
    private var setup: some View {
        VStack(spacing: 14) {
            Image(systemName: "circle.hexagongrid").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(t("Un atlas de todo lo que sabes", "An atlas of everything you know")).font(.title3.weight(.semibold))
            Text(t("Palladium coloca tus notas, las páginas de tus PDF y tus imágenes en un espacio donde lo parecido queda cerca: cada cuaderno es una región y sus temas se agrupan dentro. Lo hace con un modelo que funciona en este Mac: nada de tus cuadernos se envía a ningún servicio.",
                   "Palladium places your notes, PDF pages and pictures in a space where similar things sit close together: each notebook is a region, with its subjects clustered inside. It uses a model that runs on this Mac: nothing in your notebooks is sent to any service."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            if let download = maps.download {
                ProgressView(value: download.fraction).frame(width: 260)
                HStack(spacing: 12) {
                    Text(ByteCountFormatter.string(fromByteCount: download.received, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: download.total, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button(t("Cancelar", "Cancel")) { maps.cancelInstall() }.buttonStyle(.plain).font(.caption)
                }
            } else {
                Button { maps.install() } label: {
                    Text(t("Descargar el modelo", "Download the model") + " · " + ByteCountFormatter.string(fromByteCount: NotebookEmbeddingRuntime.downloadSize, countStyle: .file))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(NotebookAccent.color(accent).opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityIdentifier("notebook.map.install")
                Text(t("EmbeddingGemma 2 de Google, con el motor llama.cpp. Se descarga una vez y puedes eliminarlo cuando quieras.",
                       "Google's EmbeddingGemma 2, with the llama.cpp runtime. Downloaded once; you can remove it at any time."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if let error = maps.installError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: 460) }
        }.padding(30).onChange(of: maps.installed) { _, ready in if ready { model.refreshMap() } }
    }
}

// MARK: - Graph

struct NotebookAtlasCanvas: NSViewRepresentable {
    let atlas: NotebookAtlas
    let hidden: Set<Int>
    let focus: Int?
    let labels: Bool
    let hover: (Int?, CGPoint) -> Void
    let open: (Int) -> Void
    func makeNSView(context: Context) -> NotebookAtlasGraphView { NotebookAtlasGraphView(frame: .zero) }
    func updateNSView(_ view: NotebookAtlasGraphView, context: Context) {
        view.hover = hover; view.open = open
        view.show(atlas)
        if view.hiddenRegions != hidden { view.hiddenRegions = hidden }
        if view.labelsAlways != labels { view.labelsAlways = labels }
        view.focus(focus)
    }
}

/// Draws the atlas as a flat graph and lets the reader move it: dragging the background pans, dragging a point
/// pulls it and its neighbours along, the wheel or a pinch zooms. The points settle by a small force simulation
/// that runs only while something moves, so a still graph costs nothing.
final class NotebookAtlasGraphView: NSView {
    struct Node {
        var position: CGPoint
        var velocity = CGVector.zero
        /// Where the atlas placed it; a weak pull back here keeps alike places together.
        let anchor: CGPoint
        let region: Int
        let radius: CGFloat
    }
    var hover: (Int?, CGPoint) -> Void = { _, _ in }
    var open: (Int) -> Void = { _ in }
    private(set) var nodes: [Node] = []
    private(set) var edges: [(Int, Int)] = []
    private var neighbours: [Set<Int>] = []
    private var ids: [String] = []
    private var titles: [String] = []
    private var regionTitles: [String] = []
    var hiddenRegions: Set<Int> = [] { didSet { needsDisplay = true } }
    var labelsAlways = false { didSet { needsDisplay = true } }
    /// The world point at the middle of the view, and how many view points one world unit takes.
    private(set) var centre = CGPoint.zero
    private(set) var scale: CGFloat = 1
    private var built: Date?
    private var focused: Int?? = .none
    private var heat: CGFloat = 0
    private var link: CADisplayLink?
    private var flight: (from: (CGPoint, CGFloat), to: (CGPoint, CGFloat), start: CFTimeInterval)?
    private var hovered: Int?
    private var dragged: Int?
    private var pressed: CGPoint?, last: CGPoint?
    static let spread: CGFloat = 150, linkLength: CGFloat = 28

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func world(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - bounds.midX) / scale + centre.x, y: (point.y - bounds.midY) / scale + centre.y) }
    func screen(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - centre.x) * scale + bounds.midX, y: (point.y - centre.y) * scale + bounds.midY) }

    func show(_ atlas: NotebookAtlas) {
        guard atlas.built != built else { return }
        let first = built == nil
        built = atlas.built
        var degree = [Int](repeating: 0, count: atlas.points.count)
        edges = atlas.links.filter { atlas.points.indices.contains($0.from) && atlas.points.indices.contains($0.to) }.map { ($0.from, $0.to) }
        neighbours = Array(repeating: [], count: atlas.points.count)
        for (a, b) in edges { degree[a] += 1; degree[b] += 1; neighbours[a].insert(b); neighbours[b].insert(a) }
        // A point that moved keeps where the reader left it when the atlas is made again.
        let before = Dictionary(zip(ids, nodes.map(\.position)), uniquingKeysWith: { first, _ in first })
        nodes = atlas.points.enumerated().map { index, point in
            let anchor = CGPoint(x: CGFloat(point.position.first ?? 0) * Self.spread, y: -CGFloat(point.position.dropFirst().first ?? 0) * Self.spread)
            return Node(position: before[point.id] ?? anchor, anchor: anchor, region: point.region, radius: 3 + min(4, log2(1 + CGFloat(degree[index]))))
        }
        ids = atlas.points.map(\.id)
        titles = atlas.points.map { NotebookMapBuilder.clean($0.item.title) }
        regionTitles = atlas.regions.map(\.title)
        hovered = nil; dragged = nil
        if first { fit(nodes.indices, animated: false) }
        heat = 0.3; run()
    }

    // MARK: Camera

    func focus(_ region: Int?) {
        guard focused != .some(region), built != nil else { return }
        let firstTime = focused == .none
        focused = .some(region)
        if firstTime && region == nil { return }
        fit(region.map { region in nodes.indices.filter { nodes[$0].region == region } } ?? Array(nodes.indices), animated: true)
        needsDisplay = true
    }
    private func fit(_ indices: some Collection<Int>, animated: Bool) {
        // Before the view has a size, the fit waits for one.
        guard !indices.isEmpty, bounds.width > 0 else { return }
        var box = CGRect.null
        for index in indices { box = box.union(CGRect(origin: nodes[index].position, size: .zero)) }
        box = box.insetBy(dx: -40, dy: -40)
        // The region panel covers the left of the view, so the graph is fitted into the rest.
        let room = CGRect(x: min(300, bounds.width * 0.3), y: 70, width: bounds.width - min(300, bounds.width * 0.3) - 30, height: bounds.height - 120)
        let fitted = min(4, max(0.15, min(room.width / box.width, room.height / box.height)))
        let target = (CGPoint(x: box.midX - (room.midX - bounds.midX) / fitted, y: box.midY - (room.midY - bounds.midY) / fitted), fitted)
        if animated { flight = ((centre, scale), target, CACurrentMediaTime()); run() } else { (centre, scale) = target; needsDisplay = true }
    }
    private func zoom(by factor: CGFloat, around point: CGPoint) {
        let fixed = world(point)
        scale = min(6, max(0.08, scale * factor))
        centre = CGPoint(x: fixed.x - (point.x - bounds.midX) / scale, y: fixed.y - (point.y - bounds.midY) / scale)
        flight = nil; needsDisplay = true
    }
    override func setFrameSize(_ size: NSSize) {
        let empty = bounds.width == 0
        super.setFrameSize(size)
        if empty && size.width > 0 && !nodes.isEmpty {
            if case .some(.some(let region)) = focused { fit(nodes.indices.filter { nodes[$0].region == region }, animated: false) }
            else { fit(nodes.indices, animated: false) }
        }
    }

    // MARK: Simulation

    private func run() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    @objc private func frame(_ link: CADisplayLink) {
        if heat > 0.003 || dragged != nil { tick() }
        if let flight {
            let progress = min(1, (CACurrentMediaTime() - flight.start) / 0.45), eased = CGFloat(progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2)
            centre = CGPoint(x: flight.from.0.x + (flight.to.0.x - flight.from.0.x) * eased, y: flight.from.0.y + (flight.to.0.y - flight.from.0.y) * eased)
            scale = flight.from.1 * pow(flight.to.1 / flight.from.1, eased)
            if progress >= 1 { self.flight = nil }
        }
        needsDisplay = true
        if heat <= 0.003 && dragged == nil && flight == nil { link.invalidate(); self.link = nil }
    }
    /// One step: links pull alike places together, every point pushes its near neighbours away, and each is drawn
    /// gently back to where the atlas put it.
    func tick() {
        let count = nodes.count, heat = max(self.heat, dragged == nil ? 0 : 0.25)
        guard count > 0 else { return }
        for (a, b) in edges {
            let dx = nodes[b].position.x - nodes[a].position.x, dy = nodes[b].position.y - nodes[a].position.y
            let distance = max(0.01, (dx * dx + dy * dy).squareRoot()), pull = (distance - Self.linkLength) / distance * 0.06 * heat
            nodes[a].velocity.dx += dx * pull; nodes[a].velocity.dy += dy * pull
            nodes[b].velocity.dx -= dx * pull; nodes[b].velocity.dy -= dy * pull
        }
        // Pushing only reaches nearby points, found through a grid, so a step stays cheap in a large library.
        let reach: CGFloat = 60
        var grid: [Int: [Int]] = [:]
        func cell(_ point: CGPoint) -> (Int, Int) { (Int((point.x / reach).rounded(.down)), Int((point.y / reach).rounded(.down))) }
        for index in 0..<count { let (x, y) = cell(nodes[index].position); grid[x &* 73856093 ^ y &* 19349663, default: []].append(index) }
        for index in 0..<count {
            let (x, y) = cell(nodes[index].position)
            for ox in -1...1 { for oy in -1...1 {
                for other in grid[(x + ox) &* 73856093 ^ (y + oy) &* 19349663] ?? [] where other > index {
                    let dx = nodes[other].position.x - nodes[index].position.x, dy = nodes[other].position.y - nodes[index].position.y
                    let squared = max(1, dx * dx + dy * dy)
                    guard squared < reach * reach else { continue }
                    let push = 260 * heat / squared
                    nodes[index].velocity.dx -= dx * push / squared.squareRoot(); nodes[index].velocity.dy -= dy * push / squared.squareRoot()
                    nodes[other].velocity.dx += dx * push / squared.squareRoot(); nodes[other].velocity.dy += dy * push / squared.squareRoot()
                }
            } }
        }
        for index in 0..<count {
            if index == dragged { nodes[index].velocity = .zero; continue }
            nodes[index].velocity.dx = (nodes[index].velocity.dx + (nodes[index].anchor.x - nodes[index].position.x) * 0.012 * heat) * 0.6
            nodes[index].velocity.dy = (nodes[index].velocity.dy + (nodes[index].anchor.y - nodes[index].position.y) * 0.012 * heat) * 0.6
            nodes[index].position.x += nodes[index].velocity.dx; nodes[index].position.y += nodes[index].velocity.dy
        }
        if dragged == nil { self.heat *= 0.98 }
    }

    // MARK: Drawing

    private func shown(_ index: Int) -> Bool { !hiddenRegions.contains(nodes[index].region) }
    private func lit(_ index: Int) -> Bool {
        if let hovered { return index == hovered || neighbours[hovered].contains(index) }
        if case .some(.some(let region)) = focused { return nodes[index].region == region }
        return true
    }
    private func size(_ node: Node) -> CGFloat { node.radius * min(1.6, max(0.6, scale.squareRoot())) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        let view = bounds.insetBy(dx: -20, dy: -20)
        let quiet = hovered != nil || focused.flatMap { $0 } != nil
        // Lines first, faint; those of the point under the pointer stand out.
        let plain = CGMutablePath(), strong = CGMutablePath()
        for (a, b) in edges where shown(a) && shown(b) {
            let from = screen(nodes[a].position), to = screen(nodes[b].position)
            guard view.contains(from) || view.contains(to) else { continue }
            let path = hovered != nil && (a == hovered || b == hovered) ? strong : plain
            path.move(to: from); path.addLine(to: to)
        }
        context.setLineWidth(0.8)
        context.addPath(plain); context.setStrokeColor(NSColor.labelColor.withAlphaComponent(quiet ? 0.05 : 0.13).cgColor); context.strokePath()
        context.addPath(strong); context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor); context.strokePath()
        // Points, one fill per region and brightness.
        var paths: [Int: (CGMutablePath, CGMutablePath)] = [:]
        for (index, node) in nodes.enumerated() where shown(index) {
            let at = screen(node.position), radius = size(node)
            guard view.contains(at) else { continue }
            let pair = paths[node.region] ?? (CGMutablePath(), CGMutablePath())
            (lit(index) ? pair.0 : pair.1).addEllipse(in: CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2))
            paths[node.region] = pair
        }
        for (region, pair) in paths {
            let colour = NotebookAtlasPalette.nsColor(region)
            context.addPath(pair.0); context.setFillColor(colour.cgColor); context.fillPath()
            context.addPath(pair.1); context.setFillColor(colour.withAlphaComponent(0.18).cgColor); context.fillPath()
        }
        if let hovered, shown(hovered) {
            let at = screen(nodes[hovered].position), radius = size(nodes[hovered]) + 2.5
            context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.8).cgColor); context.setLineWidth(1.5)
            context.strokeEllipse(in: CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2))
        }
        drawLabels()
    }
    private func drawLabels() {
        // Names of places fade in as the reader comes closer; when far, each region is named instead.
        let fade = labelsAlways ? 1 : min(1, max(0, (scale - 1.1) * 2.5))
        if fade > 0 || hovered != nil {
            let font = NSFont.systemFont(ofSize: 10.5)
            var drawn = 0, taken: [CGRect] = []
            // The point pointed at and its neighbours are named first, so they are never the ones left out.
            let order = hovered.map { pointed in [pointed] + neighbours[pointed].sorted() + nodes.indices.filter { $0 != pointed && !neighbours[pointed].contains($0) } } ?? Array(nodes.indices)
            for index in order where shown(index) && drawn < 500 {
                let node = nodes[index]
                let near = hovered.map { $0 == index || neighbours[$0].contains(index) } ?? false
                guard fade > 0 || near else { continue }
                let at = screen(node.position)
                guard bounds.contains(at) else { continue }
                let alpha = near ? 1 : fade * (lit(index) ? 0.8 : 0.25)
                let text = NSAttributedString(string: titles[index], attributes: [.font: index == hovered ? NSFont.systemFont(ofSize: 11, weight: .semibold) : font, .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha)])
                let width = min(text.size().width, 180), frame = CGRect(x: at.x - width / 2, y: at.y + size(node) + 2, width: width, height: 14)
                // A name that would cover one already drawn is left out, unless it belongs to the point pointed at.
                guard index == hovered || !taken.contains(where: { $0.intersects(frame) }) else { continue }
                text.draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                taken.append(frame); drawn += 1
            }
        }
        guard fade < 1, hovered == nil else { return }
        var sums = [CGPoint](repeating: .zero, count: regionTitles.count), counts = [Int](repeating: 0, count: regionTitles.count), tops = [CGFloat](repeating: .infinity, count: regionTitles.count)
        for (index, node) in nodes.enumerated() where shown(index) && node.region < sums.count {
            sums[node.region].x += node.position.x; sums[node.region].y += node.position.y; counts[node.region] += 1
            tops[node.region] = min(tops[node.region], node.position.y)
        }
        for region in regionTitles.indices where counts[region] > 0 {
            let at = screen(CGPoint(x: sums[region].x / CGFloat(counts[region]), y: tops[region]))
            let dim = focused.flatMap { $0 }.map { $0 != region } ?? false
            let text = NSAttributedString(string: regionTitles[region], attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor.withAlphaComponent((1 - fade) * (dim ? 0.3 : 0.85))])
            let width = text.size().width
            text.draw(at: CGPoint(x: at.x - width / 2, y: at.y - 24))
        }
    }

    // MARK: Pointer

    /// The shown point under `location`, allowing a few points of slack around small ones.
    func node(at location: CGPoint) -> Int? {
        var best: Int?, least = CGFloat.infinity
        for (index, node) in nodes.enumerated() where shown(index) {
            let at = screen(node.position), dx = at.x - location.x, dy = at.y - location.y, distance = dx * dx + dy * dy
            let reach = max(size(node) + 3, 7)
            if distance < reach * reach && distance < least { least = distance; best = index }
        }
        return best
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    private func setHovered(_ index: Int?, at point: CGPoint) {
        if index != hovered { hovered = index; needsDisplay = true }
        hover(index, point)
    }
    override func mouseMoved(with event: NSEvent) {
        let point = location(event), index = node(at: point)
        (index == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        setHovered(index, at: point)
    }
    override func mouseExited(with event: NSEvent) { setHovered(nil, at: .zero) }
    override func mouseDown(with event: NSEvent) {
        let point = location(event)
        pressed = point; last = point
        dragged = node(at: point)
        if dragged != nil { heat = max(heat, 0.3); run() }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = location(event)
        guard let last else { return }
        if let dragged {
            nodes[dragged].position = world(point); nodes[dragged].velocity = .zero
            setHovered(dragged, at: point)
        } else {
            centre.x -= (point.x - last.x) / scale; centre.y -= (point.y - last.y) / scale
            flight = nil; needsDisplay = true
            setHovered(nil, at: .zero)
        }
        NSCursor.closedHand.set()
        self.last = point
    }
    override func mouseUp(with event: NSEvent) {
        let point = location(event)
        defer { pressed = nil; last = nil; dragged = nil; NSCursor.arrow.set() }
        guard let pressed, hypot(point.x - pressed.x, point.y - pressed.y) < 4, let index = node(at: point) else { return }
        open(index)
    }
    override func scrollWheel(with event: NSEvent) {
        // A trackpad reports pixels, a mouse wheel lines.
        let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        zoom(by: exp(amount * 0.006), around: location(event))
    }
    override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification, around: location(event)) }
}
