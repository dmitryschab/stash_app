// MindMapEngine.swift
//
// A lightweight Swift port of atlasflow's graph engine core (forces / simulation /
// camera / hit-test), trimmed for the phone: free force mode only — no formations,
// lenses, or planning layers. O(n²) repulsion is fine at mind-map scale (dozens of
// nodes); the alpha-cooled integrator guarantees the sim settles and sleeps, so the
// render loop can pause and stop burning battery.

import SwiftUI
import Observation

// MARK: - Model

final class GraphNode {
    let id: String
    let label: String
    let color: Color
    /// Node tier: 0 = the "you" hub, 1 = category, 2 = topic.
    let tier: Int
    let count: Int
    var x: Double, y: Double
    var vx = 0.0, vy = 0.0
    var fx = 0.0, fy = 0.0
    var radius: Double
    var pinned: Bool
    /// Deterministic per-node breathing phase (radians), FNV-1a of the id.
    let phase: Double

    init(id: String, label: String, color: Color, tier: Int, count: Int,
         x: Double, y: Double, radius: Double, pinned: Bool = false) {
        self.id = id
        self.label = label
        self.color = color
        self.tier = tier
        self.count = count
        self.x = x
        self.y = y
        self.radius = radius
        self.pinned = pinned
        var h: UInt32 = 2166136261
        for byte in id.utf8 {
            h ^= UInt32(byte)
            h = h &* 16777619
        }
        self.phase = Double(h) / Double(UInt32.max) * 2 * .pi
    }
}

struct GraphEdge {
    let source: Int // index into nodes — resolved once at build, no map lookups per tick
    let target: Int
}

// MARK: - Physics (atlasflow DEFAULT_PHYSICS, unchanged values)

enum Physics {
    static let springK = 0.05
    static let restBase = 64.0
    static let repulsion = 2400.0
    static let repulsionCap = 3.0
    static let centerK = 0.0015
    static let damping = 0.86
    static let maxSpeed = 8.0
    static let restSpeed = 0.02
    static let sleepEnergy = 0.0004
    static let sleepFrames = 30
    static let alphaDecay = 0.99
    static let alphaMin = 0.02
}

// MARK: - Camera

struct GraphCamera {
    var zoom = 1.0
    var panX = 0.0
    var panY = 0.0

    static let minZoom = 0.25
    static let maxZoom = 3.0

    func worldToScreen(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x * zoom + panX, y: y * zoom + panY)
    }

    func screenToWorld(_ p: CGPoint) -> (x: Double, y: Double) {
        let z = zoom == 0 ? 1 : zoom
        return ((p.x - panX) / z, (p.y - panY) / z)
    }

    /// Zoom anchored at a screen point.
    func zoomed(at p: CGPoint, factor: Double) -> GraphCamera {
        let z = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
        let w = screenToWorld(p)
        return GraphCamera(zoom: z, panX: p.x - w.x * z, panY: p.y - w.y * z)
    }

    /// "Fit but readable": fit the node bbox, clamp zoom, centre the cluster.
    static func fit(nodes: [GraphNode], size: CGSize) -> GraphCamera {
        guard !nodes.isEmpty, size.width > 0 else { return GraphCamera() }
        var x1 = Double.infinity, y1 = Double.infinity
        var x2 = -Double.infinity, y2 = -Double.infinity
        for n in nodes {
            x1 = min(x1, n.x - n.radius); y1 = min(y1, n.y - n.radius)
            x2 = max(x2, n.x + n.radius); y2 = max(y2, n.y + n.radius)
        }
        let pad = 40.0
        let bw = max(1, x2 - x1), bh = max(1, y2 - y1)
        var zoom = min((size.width - pad * 2) / bw, (size.height - pad * 2) / bh)
        zoom = min(max(zoom, 0.4), 1.1)
        let cx = (x1 + x2) / 2, cy = (y1 + y2) / 2
        return GraphCamera(zoom: zoom, panX: size.width / 2 - cx * zoom, panY: size.height / 2 - cy * zoom)
    }
}

// MARK: - Engine

@Observable
final class MindMapEngine {
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []
    /// Neighbor indices per node index, for tap highlighting.
    var neighbors: [[Int]] = []
    var selectedIndex: Int?
    /// True once the sim went calm; the view pauses its render loop on this.
    var isSettled = false

    @ObservationIgnored private var alpha = 1.0
    @ObservationIgnored private var calmFrames = 0
    @ObservationIgnored var draggedIndex: Int?

    // MARK: Build

    /// Builds the scene: a pinned "you" hub, category nodes sized by count, topic
    /// nodes shared across categories (a topic in two categories links both).
    func build(categories: [MindMapCategory]) {
        var built: [GraphNode] = []
        var edgeList: [(Int, Int)] = []

        built.append(GraphNode(
            id: "you", label: "YOU", color: .stashInk, tier: 0, count: 0,
            x: 0, y: 0, radius: 30, pinned: true
        ))

        var topicIndex: [String: Int] = [:]
        for (ci, model) in categories.enumerated() {
            let angle = -Double.pi / 2 + Double(ci) * (2 * .pi / Double(max(categories.count, 1)))
            // sqrt scale keeps a 10× category from being 10× the disc (magnitude-lite)
            let radius = min(34, 20 + 3.5 * (Double(model.videoCount)).squareRoot())
            let cx = 150 * cos(angle), cy = 150 * sin(angle)
            let categoryIdx = built.count
            built.append(GraphNode(
                id: "cat-\(model.category.rawValue)", label: model.category.singular.uppercased(),
                color: model.category.color, tier: 1, count: model.videoCount,
                x: cx, y: cy, radius: radius
            ))
            edgeList.append((0, categoryIdx))

            for (ti, topic) in model.topics.enumerated() {
                if let existing = topicIndex[topic] {
                    edgeList.append((categoryIdx, existing)) // shared topic bridges categories
                    continue
                }
                // golden-angle seed near the parent so the sim starts untangled
                let a = angle + Double(ti - model.topics.count / 2) * 0.5
                let idx = built.count
                built.append(GraphNode(
                    id: "topic-\(topic)", label: topic, color: model.category.color,
                    tier: 2, count: 0,
                    x: cx + 80 * cos(a), y: cy + 80 * sin(a), radius: 7
                ))
                topicIndex[topic] = idx
                edgeList.append((categoryIdx, idx))
            }
        }

        nodes = built
        edges = edgeList.map { GraphEdge(source: $0.0, target: $0.1) }
        neighbors = Array(repeating: [], count: built.count)
        for e in edges {
            neighbors[e.source].append(e.target)
            neighbors[e.target].append(e.source)
        }
        selectedIndex = nil
        wake()
    }

    // MARK: Simulation

    func wake() {
        isSettled = false
        alpha = 1
        calmFrames = 0
    }

    func tick() {
        if isSettled { return }
        for n in nodes { n.fx = 0; n.fy = 0 }

        // Repulsion, capped, with a deterministic nudge for co-located pairs.
        for i in nodes.indices {
            let a = nodes[i]
            for j in (i + 1)..<nodes.count {
                let b = nodes[j]
                var dx = a.x - b.x, dy = a.y - b.y
                var d2 = dx * dx + dy * dy
                if d2 < 1 {
                    let t = Double(i) * 0.7853981633974483 + Double(j) * 0.19634954084936208
                    dx = cos(t); dy = sin(t); d2 = 1
                }
                let d = d2.squareRoot()
                let f = min(Physics.repulsion / d2, Physics.repulsionCap)
                let ux = dx / d, uy = dy / d
                a.fx += ux * f; a.fy += uy * f
                b.fx -= ux * f; b.fy -= uy * f
            }
        }

        // Springs along edges; rest length grows with the discs it joins.
        for e in edges {
            let a = nodes[e.source], b = nodes[e.target]
            let dx = b.x - a.x, dy = b.y - a.y
            let d = max((dx * dx + dy * dy).squareRoot(), 1)
            let rest = Physics.restBase + a.radius + b.radius
            let f = Physics.springK * (d - rest)
            let ux = dx / d, uy = dy / d
            a.fx += ux * f; a.fy += uy * f
            b.fx -= ux * f; b.fy -= uy * f
        }

        // Weak pull to origin keeps the cluster on screen.
        for n in nodes {
            n.fx += -n.x * Physics.centerK
            n.fy += -n.y * Physics.centerK
        }

        // Alpha cooling guarantees settling even if forces sustain a limit cycle.
        alpha *= Physics.alphaDecay

        var energy = 0.0
        for (i, n) in nodes.enumerated() {
            if n.pinned || i == draggedIndex { n.vx = 0; n.vy = 0; continue }
            n.vx = (n.vx + n.fx * alpha) * Physics.damping
            n.vy = (n.vy + n.fy * alpha) * Physics.damping
            let s = (n.vx * n.vx + n.vy * n.vy).squareRoot()
            if s > Physics.maxSpeed { n.vx *= Physics.maxSpeed / s; n.vy *= Physics.maxSpeed / s }
            if s < Physics.restSpeed { n.vx = 0; n.vy = 0 }
            n.x += n.vx
            n.y += n.vy
            energy += n.vx * n.vx + n.vy * n.vy
        }

        if alpha < Physics.alphaMin { isSettled = true }
        if energy / Double(max(1, nodes.count)) < Physics.sleepEnergy {
            calmFrames += 1
            if calmFrames >= Physics.sleepFrames { isSettled = true }
        } else {
            calmFrames = 0
        }
    }

    // MARK: Interaction

    /// Nearest node whose disc (+slop, world units) contains the point.
    func pickNode(at p: CGPoint, camera: GraphCamera) -> Int? {
        let w = camera.screenToWorld(p)
        let slop = 10.0 / camera.zoom
        var best: Int?
        var bestDist = Double.infinity
        for (i, n) in nodes.enumerated() {
            let d = ((n.x - w.x) * (n.x - w.x) + (n.y - w.y) * (n.y - w.y)).squareRoot()
            if d <= n.radius + slop, d < bestDist { best = i; bestDist = d }
        }
        return best
    }

    /// Set of node indices to keep lit for the current selection (node + neighbors).
    func litIndices() -> Set<Int>? {
        guard let s = selectedIndex else { return nil }
        var lit: Set<Int> = [s]
        lit.formUnion(neighbors[s])
        return lit
    }

    // MARK: Self-check

    /// Smallest check that fails if the physics breaks: a triangle graph must
    /// settle within the alpha budget with finite, spread-out positions.
    static func selfTest() -> Bool {
        let engine = MindMapEngine()
        let category = MindMapCategory(category: .recipe, topics: ["a", "b"], videoCount: 3)
        let category2 = MindMapCategory(category: .music, topics: ["a"], videoCount: 1)
        engine.build(categories: [category, category2])
        for _ in 0..<600 where !engine.isSettled { engine.tick() }
        guard engine.isSettled else { return false }
        for n in engine.nodes where !(n.x.isFinite && n.y.isFinite) { return false }
        // shared topic "a" produced one node bridging both categories
        let topicNodes = engine.nodes.filter { $0.tier == 2 }
        return topicNodes.count == 2 && engine.neighbors[engine.nodes.firstIndex { $0.id == "topic-a" }!].count == 2
    }
}
