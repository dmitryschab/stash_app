// MindMapView.swift
//
// The Mind map tab: a live force-directed graph on the MindMapEngine (the atlasflow
// core, trimmed for the phone). You-hub → category discs sized by count → topic dots,
// with shared topics bridging categories. Pan, pinch-zoom, drag nodes, tap to spotlight
// a neighborhood. The render loop pauses whenever the sim is settled and untouched.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct MindMapView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]

    @State private var engine = MindMapEngine()
    @State private var camera = GraphCamera()
    @State private var canvasSize: CGSize = .zero

    private enum DragMode { case none, pan(GraphCamera), node(Int) }
    @State private var dragMode: DragMode = .none
    @State private var zoomBase: GraphCamera?
    @State private var hasInteracted = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                StashHeader(title: "Mind map", trailing: "\(videos.count) saves")
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                if categories.isEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    graph
                }
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Graph

    /// Run the clock only while something animates: physics awake, a spotlight
    /// pulse traveling, or a finger down. Idle+unselected = frozen frame, 0% CPU.
    private var isPaused: Bool {
        if case .none = dragMode {} else { return false }
        return engine.isSettled && engine.selectedIndex == nil
    }

    private var graph: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { context in
                Canvas { gc, size in
                    draw(in: &gc, size: size, tSec: context.date.timeIntervalSinceReferenceDate)
                }
                .onChange(of: context.date) { engine.tick() }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .gesture(magnifyGesture)
            .onTapGesture(coordinateSpace: .local) { location in
                if let hit = engine.pickNode(at: location, camera: camera) {
                    engine.selectedIndex = engine.selectedIndex == hit ? nil : hit
                } else {
                    engine.selectedIndex = nil
                }
            }
            .onAppear {
                canvasSize = geo.size
                rebuild()
            }
            .onChange(of: geo.size) {
                canvasSize = geo.size
                if !hasInteracted { camera = .fit(nodes: engine.nodes, size: canvasSize) }
            }
            .onChange(of: videos.count) { rebuild() }
            .onChange(of: engine.isSettled) {
                // re-frame the settled layout unless the user already took the camera
                if engine.isSettled, !hasInteracted {
                    withAnimation(.easeOut(duration: 0.4)) {
                        camera = .fit(nodes: engine.nodes, size: canvasSize)
                    }
                }
            }
            .overlay(alignment: .bottom) { selectionChip }
        }
        .padding(.bottom, 8)
    }

    private func rebuild() {
        hasInteracted = false
        engine.build(categories: categories)
        // let the first ticks spread the seed before fitting
        for _ in 0..<30 { engine.tick() }
        camera = .fit(nodes: engine.nodes, size: canvasSize)
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                switch dragMode {
                case .none:
                    if let hit = engine.pickNode(at: value.startLocation, camera: camera), hit != 0 {
                        dragMode = .node(hit)
                        engine.draggedIndex = hit
                    } else {
                        dragMode = .pan(camera)
                    }
                    engine.wake()
                case .pan(let base):
                    hasInteracted = true
                    camera.panX = base.panX + value.translation.width
                    camera.panY = base.panY + value.translation.height
                case .node(let index):
                    let w = camera.screenToWorld(value.location)
                    let n = engine.nodes[index]
                    n.x = w.x
                    n.y = w.y
                    n.vx = 0
                    n.vy = 0
                    engine.wake()
                }
            }
            .onEnded { _ in
                engine.draggedIndex = nil
                engine.wake()
                dragMode = .none
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                hasInteracted = true
                let base = zoomBase ?? camera
                if zoomBase == nil { zoomBase = base }
                camera = base.zoomed(at: value.startLocation, factor: value.magnification)
            }
            .onEnded { _ in zoomBase = nil }
    }

    // MARK: - Drawing (atlasflow draw pass: grid → edges+pulses → glows → nodes → labels)

    private let dimAlpha = 0.12

    private func draw(in gc: inout GraphicsContext, size: CGSize, tSec: Double) {
        let lit = engine.litIndices()
        drawGrid(&gc, size: size)
        for edge in engine.edges { drawEdge(&gc, edge: edge, lit: lit, tSec: tSec) }
        drawGlows(&gc, lit: lit, tSec: tSec)
        drawNodes(&gc, lit: lit, tSec: tSec)
    }

    /// Camera-locked dot grid; sheds itself below 0.5× zoom.
    private func drawGrid(_ gc: inout GraphicsContext, size: CGSize) {
        guard camera.zoom >= 0.5 else { return }
        let step = 44 * camera.zoom
        let ox = camera.panX.truncatingRemainder(dividingBy: step) + (camera.panX < 0 ? step : 0)
        let oy = camera.panY.truncatingRemainder(dividingBy: step) + (camera.panY < 0 ? step : 0)
        var dots = Path()
        var x = ox
        while x < size.width {
            var y = oy
            while y < size.height {
                dots.addRect(CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                y += step
            }
            x += step
        }
        gc.fill(dots, with: .color(.stashInk.opacity(0.1)))
    }

    /// Quadratic bow (calm, fixed perpendicular offset) with a traveling-dash
    /// pulse on the selected neighborhood's edges.
    private func drawEdge(_ gc: inout GraphicsContext, edge: GraphEdge, lit: Set<Int>?, tSec: Double) {
        let nodes = engine.nodes
        let a = nodes[edge.source], b = nodes[edge.target]
        let pa = camera.worldToScreen(a.x, a.y)
        let pb = camera.worldToScreen(b.x, b.y)
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let len = max((dx * dx + dy * dy).squareRoot(), 1)
        let bow = min(18, len * 0.08)
        let control = CGPoint(x: (pa.x + pb.x) / 2 - dy / len * bow, y: (pa.y + pb.y) / 2 + dx / len * bow)
        var path = Path()
        path.move(to: pa)
        path.addQuadCurve(to: pb, control: control)

        let spotlit = lit.map { $0.contains(edge.source) && $0.contains(edge.target) } ?? false
        let dimmed = lit != nil && !spotlit
        let color = nodes[max(edge.source, edge.target)].color

        if spotlit {
            gc.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.4 * camera.zoom, lineCap: .round))
            // traveling dash re-stroked over the same path
            gc.stroke(
                path,
                with: .color(.stashBackground.opacity(0.9)),
                style: StrokeStyle(
                    lineWidth: 2.2 * camera.zoom, lineCap: .round,
                    dash: [6, 88], dashPhase: -(tSec * 42).truncatingRemainder(dividingBy: 94)
                )
            )
        } else {
            let hub = min(a.tier, b.tier) == 0
            let alpha = dimmed ? 0.06 : hub ? 0.55 : 0.35
            gc.stroke(
                path,
                with: .color(.stashInk.opacity(alpha)),
                style: StrokeStyle(lineWidth: (hub ? 1.8 : 1.2) * camera.zoom, lineCap: .round)
            )
        }
    }

    /// Radial halos behind the hub and category discs, alpha-pulsing per node.
    private func drawGlows(_ gc: inout GraphicsContext, lit: Set<Int>?, tSec: Double) {
        for (i, n) in engine.nodes.enumerated() where n.tier <= 1 {
            if let lit, !lit.contains(i) { continue }
            let p = camera.worldToScreen(n.x, n.y)
            let r = n.radius * camera.zoom * 3.2
            let alpha = 0.3 + 0.12 * sin(tSec * 1.1 + n.phase)
            gc.fill(
                Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(
                    Gradient(colors: [n.color.opacity(0.45 * alpha), n.color.opacity(0)]),
                    center: p, startRadius: 0, endRadius: r
                )
            )
        }
    }

    private func drawNodes(_ gc: inout GraphicsContext, lit: Set<Int>?, tSec: Double) {
        let labelTier = camera.zoom >= 0.55 ? 2 : camera.zoom >= 0.35 ? 1 : 0
        for (i, n) in engine.nodes.enumerated() {
            let dimmed = lit.map { !$0.contains(i) } ?? false
            let opacity = dimmed ? dimAlpha : 1.0
            let p = camera.worldToScreen(n.x, n.y)
            // breathing: ±2.5% radius, per-node phase — cosmetic only
            let r = max(1.5, n.radius * (1 + 0.025 * sin(tSec * 1.4 + n.phase)) * camera.zoom)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)

            if n.tier == 2 {
                // topics are hollow: canvas fill + colored stroke (atlasflow's external tier)
                gc.fill(Path(ellipseIn: rect), with: .color(.stashBackground.opacity(opacity)))
                gc.stroke(Path(ellipseIn: rect), with: .color(n.color.opacity(opacity)), lineWidth: 1.6)
            } else {
                gc.fill(Path(ellipseIn: rect), with: .color(n.color.opacity(opacity)))
            }
            if engine.selectedIndex == i {
                let ring = rect.insetBy(dx: -7, dy: -7)
                gc.stroke(Path(ellipseIn: ring), with: .color(n.color), lineWidth: 1.8)
            }

            let selected = engine.selectedIndex == i
            switch n.tier {
            case 0:
                drawText(&gc, "YOU", at: p, size: 12 * camera.zoom, color: .stashOnInk.opacity(opacity), tracking: 1.5)
            case 1:
                drawText(&gc, n.label, at: CGPoint(x: p.x, y: p.y - 6 * camera.zoom),
                         size: 9.5 * camera.zoom, color: .stashOnAccent.opacity(opacity), tracking: 1)
                drawText(&gc, "\(n.count)", at: CGPoint(x: p.x, y: p.y + 7 * camera.zoom),
                         size: 10 * camera.zoom, color: .stashOnAccent.opacity(opacity))
            default:
                // label tiers: far views shed topic labels (free declutter)
                if !dimmed, labelTier == 2 || selected {
                    drawText(&gc, n.label, at: CGPoint(x: p.x, y: p.y + r + 11),
                             size: selected ? 13 : min(11, 11 * camera.zoom + 3),
                             color: .stashInk.opacity(selected ? 1 : 0.85))
                }
            }
        }
    }

    private func drawText(_ gc: inout GraphicsContext, _ text: String, at point: CGPoint,
                          size: CGFloat, color: Color, tracking: CGFloat = 0) {
        let resolved = gc.resolve(
            Text(text).font(.archivo(max(size, 4), .heavy)).tracking(tracking).foregroundStyle(color)
        )
        gc.draw(resolved, at: point, anchor: .center)
    }

    // MARK: - Selection chip

    @ViewBuilder
    private var selectionChip: some View {
        if let i = engine.selectedIndex, i < engine.nodes.count {
            let n = engine.nodes[i]
            HStack(spacing: 10) {
                Circle().fill(n.color).frame(width: 10, height: 10)
                Text(n.tier == 2 ? n.label : n.label.capitalized)
                    .font(.archivo(14, .bold))
                    .foregroundStyle(Color.stashInk)
                if n.tier == 1 {
                    Micro(text: "\(n.count) saves", size: 10, tracking: 1.2)
                }
                Micro(text: "\(engine.neighbors[i].count) links", size: 10, tracking: 1.2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color.stashSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.stashInk, lineWidth: 1.5))
            .padding(.bottom, stashTabBarClearance)
        }
    }

    // MARK: - Data

    /// Present categories (in tab order) with their distinct topics and counts.
    private var categories: [MindMapCategory] {
        librarySegments.compactMap { category in
            let members = videos.filter { !$0.needsLook && $0.category == category }
            guard !members.isEmpty else { return nil }

            var topics: [String] = []
            var seen = Set<String>()
            for video in members {
                for topic in video.topics where !seen.contains(topic) {
                    seen.insert(topic)
                    topics.append(topic)
                    if topics.count >= 8 { break }
                }
                if topics.count >= 8 { break }
            }
            if topics.isEmpty {
                topics = members.prefix(5).map { $0.title.isEmpty ? "untitled" : $0.title }
            }
            return MindMapCategory(category: category, topics: topics, videoCount: members.count)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.35))
            Text("No map yet")
                .font(.archivo(17, .bold))
                .foregroundStyle(Color.stashInk)
            Text("Import and process some videos to grow your mind map.")
                .font(.archivo(13))
                .foregroundStyle(Color.stashInk.opacity(0.55))
        }
    }
}

/// A single category branch of the map.
struct MindMapCategory {
    let category: Category
    let topics: [String]
    let videoCount: Int
}

#Preview {
    MindMapView()
        .modelContainer(SampleData.previewContainer)
}
