import Foundation
import Accelerate
import simd

/// Every notebook of the library laid out on a plane: each notebook is a region, its subjects are clusters inside
/// it, and every place is a point near the places that say similar things. Positions keep three values, the last
/// always zero.
public struct NotebookAtlas: Codable, Equatable, Sendable {
    public struct Region: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// The largest topics, to say what the region holds.
        public var subtitle: String
        public var centre: [Float]
        public var radius: Float
        public var count: Int
    }
    public struct Topic: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var region: Int
        public var title: String
        public var centre: [Float]
        public var count: Int
    }
    public struct Point: Codable, Equatable, Sendable, Identifiable {
        public var item: NotebookMapItem
        public var region: Int
        public var topic: Int
        public var position: [Float]
        public var id: String { item.id }
    }
    /// Two places that say much the same: each place's nearest ones, and the closest pairs across regions.
    public struct Link: Codable, Equatable, Sendable {
        public var from: Int
        public var to: Int
        public var strength: Float
    }
    /// Raised when the atlas is laid out differently, so a saved one is made again from the indexes.
    public static let currentVersion = 2
    public var version = NotebookAtlas.currentVersion
    /// Names of the notebooks it was made from, by id: a renamed or removed notebook makes it again.
    public var notebooks: [String: String]
    public var regions: [Region]
    public var topics: [Topic]
    public var points: [Point]
    public var links: [Link]
    public var built: Date

    private static let location = "maps/atlas.json"
    public static func load(workspace: SafeWorkspace) -> NotebookAtlas? {
        guard let data = try? workspace.readStorage(location), let atlas = try? JSONDecoder().decode(NotebookAtlas.self, from: data),
              atlas.version == currentVersion else { return nil }
        return atlas
    }
    public func save(workspace: SafeWorkspace) throws { try workspace.writeStorage(Self.location, data: JSONEncoder().encode(self)) }
}

public enum NotebookAtlasBuilder {
    public struct Source: Sendable {
        public var id: String
        public var name: String
        public var index: NotebookMapIndex
        public init(id: String, name: String, index: NotebookMapIndex) { self.id = id; self.name = name; self.index = index }
    }
    typealias Vector3 = SIMD3<Float>
    /// Room a cluster of `count` points needs, and the space kept between clusters and between regions.
    static func radius(_ count: Int) -> Float { 0.12 * Float(count).squareRoot() + 0.1 }
    static let topicGap: Float = 1.25, regionGap: Float = 1.4
    /// Likeness, once what all places share is taken away, below which two places are not linked.
    static let linkMinimum: Float = 0.2

    struct Group { var id: String; var title: String; var items: [String] }
    private static func places(_ node: NotebookMap.Node) -> [String] {
        if let item = node.item { return item.host == nil ? [item.id] : [] }
        return node.children.flatMap(places)
    }
    /// The topics directly under a node; places hanging straight from it are gathered under its own name.
    private static func groups(_ node: NotebookMap.Node, prefix: String) -> [Group] {
        var result: [Group] = [], rest: [String] = []
        for child in node.children {
            if child.item == nil { result.append(.init(id: prefix + child.id, title: child.title, items: places(child))) }
            else if child.item?.host == nil { rest.append(child.id) }
        }
        if !rest.isEmpty { result.append(.init(id: prefix + node.id + "/rest", title: node.title, items: rest)) }
        return result.filter { !$0.items.isEmpty }
    }

    /// Row-major `rows × inner` times `inner × columns`.
    static func multiply(_ a: [Float], _ b: [Float], rows: Int, columns: Int, inner: Int) -> [Float] {
        var result = [Float](repeating: 0, count: rows * columns)
        vDSP_mmul(a, 1, b, 1, &result, 1, vDSP_Length(rows), vDSP_Length(columns), vDSP_Length(inner))
        return result
    }
    static func transpose(_ a: [Float], rows: Int, columns: Int) -> [Float] {
        var result = [Float](repeating: 0, count: rows * columns)
        vDSP_mtrans(a, 1, &result, 1, vDSP_Length(columns), vDSP_Length(rows))
        return result
    }
    /// The three directions along which the vectors differ most, and where each vector lies along them.
    static func principal(_ rows: [[Float]]) -> [Vector3] {
        let count = rows.count
        guard count > 1, let width = rows.first?.count, width > 0 else { return [Vector3](repeating: .zero, count: count) }
        var centred = [Float](repeating: 0, count: count * width), mean = [Float](repeating: 0, count: width)
        for row in rows { for index in 0..<width { mean[index] += row[index] / Float(count) } }
        for (number, row) in rows.enumerated() { for index in 0..<width { centred[number * width + index] = row[index] - mean[index] } }
        let covariance = multiply(transpose(centred, rows: count, columns: width), centred, rows: width, columns: width, inner: count)
        var axes: [[Float]] = []
        for axis in 0..<3 {
            // Power iteration from a fixed start, so the same vectors always give the same picture.
            var direction = (0..<width).map { Float(($0 * 7 + axis * 13) % 11) - 5 + 0.5 }
            for _ in 0..<80 {
                var next = multiply(covariance, direction, rows: width, columns: 1, inner: width)
                for earlier in axes { let shared = zip(next, earlier).reduce(Float(0)) { $0 + $1.0 * $1.1 }; for index in 0..<width { next[index] -= shared * earlier[index] } }
                let length = next.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
                guard length > 1e-12 else { break }
                direction = next.map { $0 / length }
            }
            axes.append(direction)
        }
        var result = [Vector3](repeating: .zero, count: count)
        for axis in 0..<3 {
            let values = multiply(centred, axes[axis], rows: count, columns: 1, inner: width)
            // The sign of an axis is arbitrary; the longer tail points the positive way.
            let sign: Float = values.reduce(0) { $0 + $1 * $1 * $1 } < 0 ? -1 : 1
            for index in 0..<count { result[index][axis] = values[index] * sign }
        }
        return result
    }
    /// Evenly spread directions on the plane.
    static func circle(_ count: Int) -> [Vector3] {
        (0..<count).map { index in let angle = Float(index) * 2.399963; return Vector3(cos(angle), sin(angle), 0) }
    }
    /// The two leading principal directions, as positions on the plane.
    static func flat(_ rows: [[Float]]) -> [Vector3] { principal(rows).map { Vector3($0.x, $0.y, 0) } }
    static func seed(_ text: String) -> UInt64 { text.utf8.reduce(14695981039346656037) { ($0 ^ UInt64($1)) &* 1099511628211 } }

    /// Places groups of the given sizes so that similar ones are near and none overlaps another.
    static func arrange(_ means: [[Float]], radii: [Float], gap: Float) -> [Vector3] {
        let count = means.count
        guard count > 1 else { return [Vector3](repeating: .zero, count: count) }
        var positions = flat(means)
        let reach = positions.map { simd_length($0) }.max() ?? 0, room = radii.reduce(0, +) / Float(count) * gap * Float(count).squareRoot()
        positions = reach > 1e-6 ? positions.map { $0 * (room / reach) } : circle(count).map { $0 * room }
        func separate() -> Bool {
            var moved = false
            for first in 0..<count {
                for second in first + 1..<count {
                    var apart = positions[second] - positions[first], distance = simd_length(apart)
                    let wanted = (radii[first] + radii[second]) * gap
                    guard distance < wanted else { continue }
                    if distance < 1e-5 { apart = circle(count)[second]; distance = 1e-5 }
                    let push = simd_normalize(apart) * (wanted - distance) / 2
                    positions[first] -= push; positions[second] += push; moved = true
                }
            }
            return moved
        }
        // Drawn together, then pushed apart where they overlap: similar groups end up side by side.
        for _ in 0..<60 {
            let middle = positions.reduce(Vector3.zero, +) / Float(count)
            positions = positions.map { middle + ($0 - middle) * 0.97 }
            for _ in 0..<4 where separate() {}
        }
        for _ in 0..<300 where separate() {}
        let middle = positions.reduce(Vector3.zero, +) / Float(count)
        return positions.map { $0 - middle }
    }
    /// Places the points of one topic in a disc: their directions follow how they differ, their distances from
    /// the middle are spread so the disc is evenly full.
    static func fill(_ vectors: [[Float]], radius: Float) -> [Vector3] {
        let count = vectors.count
        guard count > 1 else { return [Vector3](repeating: .zero, count: count) }
        let spread = flat(vectors), even = circle(count)
        let order = spread.indices.sorted { simd_length(spread[$0]) < simd_length(spread[$1]) }
        var result = [Vector3](repeating: .zero, count: count)
        for (rank, index) in order.enumerated() {
            let direction = simd_length(spread[index]) > 1e-6 ? simd_normalize(spread[index]) : even[index]
            result[index] = direction * radius * ((Float(rank) + 0.5) / Float(count)).squareRoot()
        }
        return result
    }
    /// The quarter turn or mirror of the plane that brings `now` closest to `before`, so a new atlas faces the way the old one did.
    static func orientation(_ now: [Vector3], _ before: [Vector3]) -> simd_float3x3 {
        var best = matrix_identity_float3x3, least = Float.infinity
        guard !now.isEmpty else { return best }
        for order in [[0, 1, 2], [1, 0, 2]] {
            for signs in 0..<4 {
                var columns = [Vector3](repeating: .zero, count: 3)
                for axis in 0..<3 { columns[axis][order[axis]] = signs & (1 << axis) == 0 ? 1 : -1 }
                let turn = simd_float3x3(columns: (columns[0], columns[1], columns[2]))
                let distance = zip(now, before).reduce(Float(0)) { $0 + simd_distance_squared(turn * $1.0, $1.1) }
                if distance < least - 1e-6 { least = distance; best = turn }
            }
        }
        return best
    }
    /// What all places share (one language, one kind of writing) is taken away, so that only what is particular to
    /// each place makes two of them alike.
    static func centred(_ vectors: [[Float]]) -> [[Float]] {
        guard let width = vectors.first(where: { !$0.isEmpty })?.count else { return vectors }
        var middle = [Float](repeating: 0, count: width)
        let present = vectors.filter { $0.count == width }
        for vector in present { for index in 0..<width { middle[index] += vector[index] / Float(present.count) } }
        return vectors.map { vector in vector.count == width ? NotebookMapBuilder.unit(zip(vector, middle).map { $0 - $1 }) : vector }
    }
    /// Each place joined to the `count` places most like it, wherever they are.
    static func neighbours(_ vectors: [[Float]], count: Int = 2) -> [NotebookAtlas.Link] {
        let present = vectors.indices.filter { !vectors[$0].isEmpty }
        guard present.count > 1, let width = vectors.first(where: { !$0.isEmpty })?.count else { return [] }
        let all = transpose(present.flatMap { vectors[$0] }, rows: present.count, columns: width)
        var pairs: [Int: NotebookAtlas.Link] = [:]
        // Compared in blocks, so a large library never holds every likeness at once.
        for start in stride(from: 0, to: present.count, by: 256) {
            let block = Array(present[start..<min(present.count, start + 256)])
            let scores = multiply(block.flatMap { vectors[$0] }, all, rows: block.count, columns: present.count, inner: width)
            for (row, index) in block.enumerated() {
                let best = (0..<present.count).filter { present[$0] != index }.sorted { scores[row * present.count + $0] > scores[row * present.count + $1] }.prefix(count)
                for column in best {
                    let other = present[column], key = min(index, other) * vectors.count + max(index, other)
                    if pairs[key] == nil { pairs[key] = .init(from: min(index, other), to: max(index, other), strength: scores[row * present.count + column]) }
                }
            }
        }
        return pairs.values.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
    }
    /// The strongest likenesses between places of different regions, a few for each pair of regions.
    static func bridges(_ vectors: [[Float]], regions: [Int], regionCount: Int) -> [NotebookAtlas.Link] {
        guard regionCount > 1, let width = vectors.first(where: { !$0.isEmpty })?.count else { return [] }
        var members = [[Int]](repeating: [], count: regionCount)
        for (index, region) in regions.enumerated() where !vectors[index].isEmpty { members[region].append(index) }
        // A large region is compared through an even sample of its places.
        members = members.map { list in list.count <= 400 ? list : stride(from: 0, to: list.count, by: list.count / 400 + 1).map { list[$0] } }
        var found: [NotebookAtlas.Link] = []
        for first in 0..<regionCount {
            for second in first + 1..<regionCount where !members[first].isEmpty && !members[second].isEmpty {
                let a = members[first], b = members[second]
                let scores = multiply(a.flatMap { vectors[$0] }, transpose(b.flatMap { vectors[$0] }, rows: b.count, columns: width), rows: a.count, columns: b.count, inner: width)
                var best: [(Float, Int, Int)] = []
                for row in 0..<a.count {
                    var column = 0
                    for other in 1..<b.count where scores[row * b.count + other] > scores[row * b.count + column] { column = other }
                    best.append((scores[row * b.count + column], a[row], b[column]))
                }
                found += best.sorted { $0.0 > $1.0 }.prefix(3).map { .init(from: $0.1, to: $0.2, strength: $0.0) }
            }
        }
        return Array(found.filter { $0.strength >= linkMinimum }.sorted { $0.strength > $1.strength }.prefix(max(8, regionCount * 4)))
    }

    /// `previous` keeps the atlas facing the same way when it is made again.
    public static func build(_ sources: [Source], previous: NotebookAtlas? = nil, now: Date = Date()) -> NotebookAtlas {
        var vectors: [String: [Float]] = [:], items: [String: NotebookMapItem] = [:], hosted: [String: [NotebookMapItem]] = [:]
        var maps: [(Source, NotebookMap)] = []
        for source in sources {
            for entry in source.index.entries {
                if let host = entry.item.host { hosted[host, default: []].append(entry.item); continue }
                let vector = NotebookMapIndex.unpack(entry.vector)
                guard !vector.isEmpty else { continue }
                vectors[entry.item.id] = NotebookMapBuilder.unit(vector); items[entry.item.id] = entry.item
            }
            // A small notebook may really hold only two subjects; a larger one is divided as its own tree would be.
            let size = source.index.entries.filter { $0.item.host == nil && !$0.vector.isEmpty }.count
            let map = NotebookMapBuilder.build(name: source.name, index: source.index, fewest: size < 24 ? 2 : nil, now: now)
            if map.root.places > 0 { maps.append((source, map)) }
        }
        // Several notebooks are regions of their own; a single notebook is divided into its subjects instead.
        var specs: [(id: String, title: String, topics: [Group])] = []
        if maps.count == 1, let (source, map) = maps.first {
            let prefix = source.id + ":"
            for group in groups(map.root, prefix: prefix) {
                let node = map.root.children.first { prefix + $0.id == group.id }
                let inner = node.map { groups($0, prefix: prefix) } ?? []
                specs.append((group.id, group.title, inner.count > 1 ? inner : [group]))
            }
        } else {
            for (source, map) in maps { specs.append((source.id, source.name, groups(map.root, prefix: source.id + ":"))) }
        }

        var regions: [NotebookAtlas.Region] = [], topics: [NotebookAtlas.Topic] = [], points: [NotebookAtlas.Point] = []
        var offsets: [[Vector3]] = [], local: [[Vector3]] = [], means: [[Float]] = [], radii: [Float] = []
        func mean(_ ids: [String]) -> [Float] {
            var sum = [Float](repeating: 0, count: NotebookEmbeddingRuntime.dimensions)
            for id in ids { if let vector = vectors[id], vector.count == sum.count { for index in sum.indices { sum[index] += vector[index] } } }
            return NotebookMapBuilder.unit(sum)
        }
        let before = Dictionary((previous?.points ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for spec in specs {
            let region = regions.count
            let topicRadii = spec.topics.map { radius($0.items.count) }
            let centres = arrange(spec.topics.map { mean($0.items) }, radii: topicRadii, gap: topicGap)
            var inside: [Vector3] = []
            let start = points.count
            for (number, group) in spec.topics.enumerated() {
                let present = group.items.filter { vectors[$0] != nil }
                let spread = fill(present.map { vectors[$0]! }, radius: topicRadii[number])
                topics.append(.init(id: group.id, region: region, title: NotebookMapBuilder.clean(group.title), centre: [], count: present.count))
                for (index, id) in present.enumerated() {
                    points.append(.init(item: items[id]!, region: region, topic: topics.count - 1, position: []))
                    inside.append(centres[number] + spread[index])
                }
            }
            // A region keeps the way it faced, whatever happens elsewhere in the library.
            let shared = (start..<points.count).compactMap { index in before[points[index].id].flatMap { old -> (Vector3, Vector3)? in
                guard let oldRegion = previous?.regions[safe: old.region], old.position.count == 3, oldRegion.centre.count == 3 else { return nil }
                return (inside[index - start], Vector3(old.position[0], old.position[1], old.position[2]) - Vector3(oldRegion.centre[0], oldRegion.centre[1], oldRegion.centre[2]))
            } }
            let turn = orientation(shared.map(\.0), shared.map(\.1))
            inside = inside.map { turn * $0 }
            local.append(inside); offsets.append(spec.topics.indices.map { turn * centres[$0] })
            let reach = zip(centres, topicRadii).map { simd_length($0.0) + $0.1 }.max() ?? 0.1
            radii.append(max(reach, 0.2)); means.append(mean(spec.topics.flatMap(\.items)))
            let largest = spec.topics.sorted { $0.items.count > $1.items.count }.map { NotebookMapBuilder.clean($0.title) }.filter { $0 != NotebookMapBuilder.clean(spec.title) }
            regions.append(.init(id: spec.id, title: NotebookMapBuilder.clean(spec.title), subtitle: largest.prefix(2).joined(separator: " · "), centre: [], radius: radii[region], count: points.count - start))
        }
        // The regions keep the way they faced as a whole; each one's inside was already turned on its own.
        var placed = arrange(means, radii: radii, gap: regionGap)
        let oldCentres = Dictionary((previous?.regions ?? []).map { ($0.id, $0.centre) }, uniquingKeysWith: { first, _ in first })
        let shared = regions.indices.compactMap { index -> (Vector3, Vector3)? in
            guard let old = oldCentres[regions[index].id], old.count == 3 else { return nil }
            return (placed[index], Vector3(old[0], old[1], old[2]))
        }
        let turn = orientation(shared.map(\.0), shared.map(\.1))
        placed = placed.map { turn * $0 }
        var first = 0, topicIndex = 0
        for region in regions.indices {
            let centre = placed[region]
            regions[region].centre = [centre.x, centre.y, centre.z]
            for (offset, position) in local[region].enumerated() { let at = centre + position; points[first + offset].position = [at.x, at.y, at.z] }
            first += regions[region].count
            for offset in offsets[region] { let at = centre + offset; topics[topicIndex].centre = [at.x, at.y, at.z]; topicIndex += 1 }
        }
        let alike = centred(points.map { vectors[$0.id] ?? [] })
        var links = neighbours(alike)
        let joined = Set(links.map { [$0.from, $0.to] })
        links += bridges(alike, regions: points.map(\.region), regionCount: regions.count).filter { !joined.contains([min($0.from, $0.to), max($0.from, $0.to)]) }
        // Pictures shown in a note sit beside the section that shows them.
        var hostedPoints: [NotebookAtlas.Point] = []
        for (host, point) in points.enumerated() {
            for (number, picture) in (hosted[point.id] ?? []).enumerated() {
                links.append(.init(from: host, to: points.count + hostedPoints.count, strength: 1))
                var generator = SplitMix(seed: seed(picture.id))
                let angle = Float.random(in: 0..<(2 * .pi), using: &generator), direction = Vector3(cos(angle), sin(angle), 0)
                let at = Vector3(point.position[0], point.position[1], point.position[2]) + direction * (0.06 + 0.02 * Float(number))
                hostedPoints.append(.init(item: picture, region: point.region, topic: point.topic, position: [at.x, at.y, at.z]))
            }
        }
        for index in hostedPoints.indices { regions[hostedPoints[index].region].count += 1; topics[hostedPoints[index].topic].count += 1 }
        return NotebookAtlas(notebooks: Dictionary(sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                             regions: regions, topics: topics, points: points + hostedPoints, links: links, built: now)
    }
}

/// A small generator that gives the same numbers for the same seed.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
