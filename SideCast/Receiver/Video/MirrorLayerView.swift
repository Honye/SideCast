//
//  MirrorLayerView.swift
//  SideCast
//
//  Hosts the mirror renderer's display layer in SwiftUI, filling the view (the layer letterboxes).
//

import AVFoundation
import SwiftUI

#if os(macOS)
final class MirrorLayerHostView: NSView {
    private let displayLayer: CALayer

    init(displayLayer: CALayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .black
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

struct MirrorLayerView: NSViewRepresentable {
    let renderer: MirrorRenderer

    func makeNSView(context: Context) -> MirrorLayerHostView {
        MirrorLayerHostView(displayLayer: renderer.layer)
    }

    func updateNSView(_ view: MirrorLayerHostView, context: Context) {}
}
#else
final class MirrorLayerHostView: UIView {
    private let displayLayer: CALayer

    init(displayLayer: CALayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

struct MirrorLayerView: UIViewRepresentable {
    let renderer: MirrorRenderer

    func makeUIView(context: Context) -> MirrorLayerHostView {
        MirrorLayerHostView(displayLayer: renderer.layer)
    }

    func updateUIView(_ view: MirrorLayerHostView, context: Context) {}
}
#endif
