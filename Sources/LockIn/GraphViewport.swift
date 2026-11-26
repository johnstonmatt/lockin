import SwiftUI

struct GraphCamera {
    var scale: CGFloat = 1
    var offset = CGSize.zero

    mutating func zoom(to requestedScale: CGFloat, around anchor: CGPoint) {
        let nextScale = min(2, max(0.1, requestedScale))
        let ratio = nextScale / scale
        offset = CGSize(width: anchor.x - (anchor.x - offset.width) * ratio,
                        height: anchor.y - (anchor.y - offset.height) * ratio)
        scale = nextScale
    }

    mutating func fit(content: CGSize, viewport: CGSize) {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        scale = min(1, max(0.1, min(max(1, viewport.width - 64) / content.width,
                                  max(1, viewport.height - 96) / content.height)))
        offset = CGSize(width: (viewport.width - content.width * scale) / 2,
                        height: (viewport.height - content.height * scale) / 2)
    }
}

struct GraphViewport<Content: View>: View {
    let contentSize: CGSize
    var fitRevision = 0
    @ViewBuilder var content: Content
    @State private var camera = GraphCamera()
    @State private var pinchStart: GraphCamera?
    @GestureState private var pan = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .updating($pan) { value, translation, _ in translation = value.translation }
                            .onEnded { value in
                                camera.offset.width += value.translation.width
                                camera.offset.height += value.translation.height
                            }
                    )
                    .accessibilityLabel("Graph canvas")
                    .accessibilityHint("Drag empty space to pan. Use the zoom controls to change the scale.")

                content
                    .frame(width: contentSize.width, height: contentSize.height)
                    .scaleEffect(camera.scale, anchor: .topLeading)
                    .offset(x: camera.offset.width + pan.width, y: camera.offset.height + pan.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            // Visual clipping alone does not constrain hit testing of transformed cards.
            .contentShape(Rectangle())
            .clipped()
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchStart == nil { pinchStart = camera }
                        guard var next = pinchStart else { return }
                        next.zoom(to: next.scale * value.magnification,
                                  around: CGPoint(x: value.startAnchor.x * geometry.size.width,
                                                  y: value.startAnchor.y * geometry.size.height))
                        camera = next
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 12) {
                    Button {
                        zoom(by: 1 / 1.2, in: geometry.size)
                    } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Zoom out").disabled(camera.scale <= 0.1)
                    Text(camera.scale, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 40)
                    Button {
                        zoom(by: 1.2, in: geometry.size)
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Zoom in").disabled(camera.scale >= 2)
                    Divider().frame(height: 16)
                    Button("Fit graph", systemImage: "arrow.up.left.and.arrow.down.right") {
                        camera.fit(content: contentSize, viewport: geometry.size)
                    }
                }
                .buttonStyle(.pointer(.plain))
                .font(.caption)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(16)
            }
            .onChange(of: fitRevision) { _, _ in camera.fit(content: contentSize, viewport: geometry.size) }
            .onAppear { camera.fit(content: contentSize, viewport: geometry.size) }
            .onChange(of: geometry.size) { old, new in
                camera.offset.width += (new.width - old.width) / 2
                camera.offset.height += (new.height - old.height) / 2
            }
        }
    }

    private func zoom(by factor: CGFloat, in size: CGSize) {
        camera.zoom(to: camera.scale * factor, around: CGPoint(x: size.width / 2, y: size.height / 2))
    }
}
