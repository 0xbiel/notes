import Foundation

/// A notebook divided into topics: the subjects found in it, and the places that deal with each. The atlas
/// draws these as clusters.
public struct NotebookMap: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// Set on the ends of the map, which open a place in the notebook.
        public var item: NotebookMapItem?
        public var children: [Node]
        public init(id: String, title: String, item: NotebookMapItem? = nil, children: [Node] = []) {
            self.id = id; self.title = title; self.item = item; self.children = children
        }
        public var places: Int { item != nil ? 1 : children.reduce(0) { $0 + $1.places } }
    }
    public var root: Node
    public var built: Date
    public init(root: Node, built: Date = Date()) { self.root = root; self.built = built }
}

public enum NotebookMapBuilder {
    /// Fewer places than this are shown by file: there is too little to find subjects in.
    static let clusteringMinimum = 8
    /// A topic with more places than this is divided again, up to `depthLimit` levels.
    static let topicLimit = 12, depthLimit = 3

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) { sum += a[index] * b[index] }
        return sum
    }
    static func unit(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }

    /// Ward's hierarchical clustering: the two groups whose union adds least spread are joined, again and again,
    /// until one remains. Leaves are `0..<count`; join `i` makes group `count + i`. The same vectors always give
    /// the same tree, and a change in one corner of the notebook leaves the rest of the tree as it was.
    struct Tree {
        var parts: [(Int, Int)] = [], heights: [Float] = [], means: [[Float]], sizes: [Int]
        let count: Int
        var top: Int { means.count - 1 }
        func height(_ group: Int) -> Float { group < count ? 0 : heights[group - count] }
        func leaves(_ group: Int) -> [Int] {
            var result: [Int] = [], stack = [group]
            while let next = stack.popLast() { if next < count { result.append(next) } else { let pair = parts[next - count]; stack.append(pair.1); stack.append(pair.0) } }
            return result
        }
        /// Divides a group along the tree into between `least` and `most` parts, stopping before the first
        /// division that would separate things much closer together than the one before it.
        func divide(_ group: Int, least: Int, most: Int) -> [Int] {
            var groups = [group], history: [[Int]] = [[group]], steps: [Float] = []
            while groups.count <= most, let widest = groups.indices.filter({ groups[$0] >= count }).max(by: { height(groups[$0]) < height(groups[$1]) }) {
                let pair = parts[groups[widest] - count]
                steps.append(height(groups[widest]))
                groups.replaceSubrange(widest...widest, with: [pair.0, pair.1])
                history.append(groups)
            }
            // history[n] holds n + 1 parts and was reached by a step of height steps[n - 1].
            let upper = min(most, history.count)
            guard upper > least else { return history[min(max(least, 1), history.count) - 1] }
            var best = least, ratio: Float = -1
            for parts in least...upper where parts >= 2 {
                let next = parts - 1 < steps.count ? steps[parts - 1] : 0
                let gain = steps[parts - 2] / max(next, 1e-6)
                if gain > ratio * 1.02 { ratio = gain; best = parts }
            }
            return history[best - 1]
        }
    }
    static func tree(_ vectors: [[Float]]) -> Tree {
        let count = vectors.count
        var tree = Tree(means: vectors, sizes: [Int](repeating: 1, count: count), count: count)
        guard count > 1 else { return tree }
        var alive = [Bool](repeating: true, count: count), remaining = count, chain: [Int] = []
        func spread(_ a: Int, _ b: Int) -> Float {
            var distance: Float = 0
            let first = tree.means[a], second = tree.means[b]
            for index in first.indices { let difference = first[index] - second[index]; distance += difference * difference }
            return distance * Float(tree.sizes[a] * tree.sizes[b]) / Float(tree.sizes[a] + tree.sizes[b])
        }
        // Each group is followed to its nearest neighbour until two are nearest to each other; those are joined.
        while remaining > 1 {
            if chain.isEmpty { chain.append(alive.firstIndex(of: true)!) }
            let current = chain[chain.count - 1], before = chain.count > 1 ? chain[chain.count - 2] : -1
            var nearest = before, least = before >= 0 ? spread(current, before) : Float.infinity
            for other in alive.indices where alive[other] && other != current && other != before {
                let distance = spread(current, other)
                if distance < least { least = distance; nearest = other }
            }
            guard nearest == before else { chain.append(nearest); continue }
            chain.removeLast(2)
            let first = min(current, before), second = max(current, before), size = tree.sizes[first] + tree.sizes[second]
            var mean = [Float](repeating: 0, count: tree.means[first].count)
            for index in mean.indices { mean[index] = (tree.means[first][index] * Float(tree.sizes[first]) + tree.means[second][index] * Float(tree.sizes[second])) / Float(size) }
            alive[first] = false; alive[second] = false; alive.append(true)
            tree.parts.append((first, second)); tree.heights.append(least); tree.means.append(mean); tree.sizes.append(size)
            remaining -= 1
        }
        return tree
    }

    public static func clean(_ title: String) -> String {
        var text = title.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "[*`]|(?<![\\p{L}\\p{N}])_|_(?![\\p{L}\\p{N}])", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":#")))
        return text.count > 70 ? String(text.prefix(69)) + "…" : text
    }

    private struct Point { let entry: NotebookMapIndex.Entry; let vector: [Float] }
    private struct Context {
        var points: [Point]
        var tree: Tree
        var titles: [String: [Float]]
        /// Pictures shown in a note, by the section that shows them.
        var hosted: [String: [NotebookMapIndex.Entry]]
        /// How many places each file and each folder has in the whole notebook.
        var fileSizes: [String: Int], folderSizes: [String: Int]
        /// Topics of the map being replaced, with the places each held.
        var before: [(id: String, depth: Int, places: Set<String>)]
        /// Fewest subjects the notebook is divided into, when given.
        var fewest: Int?
    }
    private static func topics(_ node: NotebookMap.Node, depth: Int, into result: inout [(id: String, depth: Int, places: Set<String>)]) -> Set<String> {
        if let item = node.item { return item.host == nil ? [item.id] : [] }
        var places = Set<String>()
        for child in node.children { places.formUnion(topics(child, depth: depth + 1, into: &result)) }
        if node.id.hasPrefix("t\(depth - 1)/") { result.append((node.id, depth - 1, places)) }
        return places
    }

    private static func leaves(_ points: [Point], _ context: Context) -> [NotebookMap.Node] {
        points.flatMap { point in
            [NotebookMap.Node(id: point.entry.item.id, title: clean(point.entry.item.title), item: point.entry.item)]
                + (context.hosted[point.entry.item.id] ?? []).map { .init(id: $0.item.id, title: clean($0.item.title), item: $0.item) }
        }
    }
    /// Places of one file under a node named after it, unless `under` already is that name.
    private static func byFile(_ points: [Point], id: String, under: String, _ context: Context) -> [NotebookMap.Node] {
        var order: [String] = [], groups: [String: [Point]] = [:]
        for point in points { if groups[point.entry.item.path] == nil { order.append(point.entry.item.path) }; groups[point.entry.item.path, default: []].append(point) }
        return order.flatMap { path -> [NotebookMap.Node] in
            let members = groups[path]!, name = clean(members[0].entry.item.file)
            let ends = leaves(members, context)
            return ends.count < 2 || name == under ? ends : [.init(id: id + "/" + path, title: name, children: ends)]
        }
    }
    /// A topic takes the widest name that is true of it: the folder it holds most of, the file when it is one whole
    /// file, both names when it joins two files, otherwise the file name (or, inside one file, the heading) nearest
    /// to what its places have in common.
    private static func label(_ members: [Point], mean: [Float], others: [[Float]], taken: Set<String>, _ context: Context) -> String {
        let files = Set(members.map(\.entry.item.path))
        func free(_ name: String?) -> String? { name.map(clean).flatMap { $0.isEmpty || taken.contains($0) ? nil : $0 } }
        var folders: [String: Int] = [:]
        for member in members { if let folder = member.entry.item.folder { folders[folder, default: 0] += 1 } }
        // A folder names the topic that holds most of it, not one of several that share it.
        if files.count > 1, let common = folders.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), common.value * 5 >= members.count * 4,
           common.value * 5 >= (context.folderSizes[common.key] ?? 0) * 4, let name = free(common.key) { return name }
        if files.count == 1, context.fileSizes[files.first!] == members.count, let name = free(members[0].entry.item.file) { return name }
        // Two files are both named: neither alone says what the topic holds.
        if files.count == 2 {
            var names: [String] = []
            for member in members where !names.contains(clean(member.entry.item.file)) { names.append(clean(member.entry.item.file)) }
            if names.count == 2, let name = free(names.joined(separator: " · ")), name.count <= 48 { return name }
        }
        let centre = unit(mean)
        var best: (String, Float)?
        for name in Set(members.map { files.count > 1 ? $0.entry.item.file : $0.entry.item.title }).sorted() {
            guard let shown = free(name), let vector = context.titles[name] else { continue }
            let apart = others.isEmpty ? 0 : others.reduce(Float(0)) { $0 + dot(vector, $1) } / Float(others.count)
            let share = Float(members.filter { $0.entry.item.file == name }.count) / Float(members.count)
            let score = dot(vector, centre) - 0.5 * apart + 0.15 * share
            if best == nil || score > best!.1 { best = (shown, score) }
        }
        if let best { return best.0 }
        // Pictures have no names to compare: the one nearest the middle stands for the group.
        return members.max { dot($0.vector, centre) < dot($1.vector, centre) }.map { clean($0.entry.item.title) } ?? ""
    }
    private static func divide(_ group: Int, loose: [Point], id: String, title: String, depth: Int, claimed: inout Set<String>, _ context: Context) -> [NotebookMap.Node] {
        let members = context.tree.leaves(group).sorted().map { context.points[$0] }
        guard members.count > (depth == 0 ? clusteringMinimum - 1 : topicLimit), depth < depthLimit else {
            // Places of several files are gathered under each file's name.
            let all = members + loose
            return Set(all.map(\.entry.item.path)).count > 1 ? byFile(all, id: id, under: title, context) : leaves(all, context)
        }
        // A larger notebook starts with more subjects: about five for fifty places, never fewer than three.
        let least = context.fewest ?? min(6, max(3, Int((Double(members.count) / 2).squareRoot().rounded())))
        let groups = depth == 0 ? context.tree.divide(group, least: least, most: max(least, min(8, members.count / 2))) : context.tree.divide(group, least: 2, most: 5)
        let centres = groups.map { unit(context.tree.means[$0]) }
        var looseBy: [Int: [Point]] = [:]
        for point in loose { looseBy[centres.indices.max { dot(point.vector, centres[$0]) < dot(point.vector, centres[$1]) }!, default: []].append(point) }
        var taken: Set<String> = [title], nodes: [NotebookMap.Node] = []
        // Topics follow the notebook's own order, by the first place each one holds.
        for index in groups.indices.sorted(by: { context.tree.leaves(groups[$0]).min()! < context.tree.leaves(groups[$1]).min()! }) {
            let inside = context.tree.leaves(groups[index]).sorted().map { context.points[$0] }
            let name = label(inside, mean: context.tree.means[groups[index]], others: centres.indices.filter { $0 != index }.map { centres[$0] }, taken: taken, context)
            taken.insert(name)
            // A topic that still holds most of what it held keeps its identity, so it stays open or closed as it was.
            let places = Set(inside.map(\.entry.item.id))
            var nodeID = "t\(depth)/" + inside[0].entry.item.id, overlap = 0.5
            for old in context.before where old.depth == depth && !claimed.contains(old.id) {
                let shared = Double(old.places.intersection(places).count) / Double(max(1, old.places.union(places).count))
                if shared > overlap { overlap = shared; nodeID = old.id }
            }
            while claimed.contains(nodeID) { nodeID += "+" }
            claimed.insert(nodeID)
            nodes.append(.init(id: nodeID, title: name, children: divide(groups[index], loose: looseBy[index] ?? [], id: nodeID, title: name, depth: depth + 1, claimed: &claimed, context)))
        }
        return nodes
    }

    /// `previous` lets topics that persist keep their identity. `fewest` lets the notebook split in as few subjects
    /// as it really has, instead of the several a readable tree wants.
    public static func build(name: String, index: NotebookMapIndex, previous: NotebookMap? = nil, fewest: Int? = nil, now: Date = Date()) -> NotebookMap {
        var hosted: [String: [NotebookMapIndex.Entry]] = [:], text: [Point] = [], visual: [Point] = []
        for entry in index.entries {
            if let host = entry.item.host { hosted[host, default: []].append(entry); continue }
            let vector = NotebookMapIndex.unpack(entry.vector)
            guard !vector.isEmpty else { continue }
            if entry.item.visual { visual.append(.init(entry: entry, vector: vector)) } else { text.append(.init(entry: entry, vector: vector)) }
        }
        // A notebook of pictures alone is arranged by the pictures themselves.
        let points = text.isEmpty ? visual : text, loose = text.isEmpty ? [] : visual
        var fileSizes: [String: Int] = [:]
        var folderSizes: [String: Int] = [:]
        for point in points {
            fileSizes[point.entry.item.path, default: 0] += 1
            if let folder = point.entry.item.folder { folderSizes[folder, default: 0] += 1 }
        }
        let tree = tree(points.map(\.vector))
        var before: [(id: String, depth: Int, places: Set<String>)] = []
        if let previous { _ = topics(previous.root, depth: 0, into: &before) }
        let context = Context(points: points, tree: tree, titles: index.titles.mapValues(NotebookMapIndex.unpack), hosted: hosted, fileSizes: fileSizes, folderSizes: folderSizes, before: before, fewest: fewest)
        var claimed = Set<String>()
        let children = points.isEmpty ? [] : divide(tree.top, loose: loose, id: "t", title: clean(name), depth: 0, claimed: &claimed, context)
        return NotebookMap(root: .init(id: "root", title: name, children: children), built: now)
    }
}
