//
//  CanvasHostView.swift
//  Bitarf RI
//
//  SwiftUI's bridge to the UIKit canvas. The canvas stays UIKit because the
//  things it has to do well — a scroll view that only draws what is visible,
//  gesture arbitration between "drag the object" and "scroll the paper", and a
//  first-responder text view — are all things UIKit already does correctly.
//

import SwiftUI

struct CanvasHostView: UIViewControllerRepresentable {

    @EnvironmentObject private var editor: EditorState

    /// Called when a press lands on overlapping objects and the user has to say
    /// which one they meant.
    var onDisambiguate: ([UUID]) -> Void

    func makeUIViewController(context: Context) -> CanvasViewController {
        let controller = CanvasViewController(editor: editor)
        controller.onDisambiguate = onDisambiguate
        return controller
    }

    func updateUIViewController(_ controller: CanvasViewController, context: Context) {
        controller.onDisambiguate = onDisambiguate
        controller.refresh()
    }
}
