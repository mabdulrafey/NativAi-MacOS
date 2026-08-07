/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI
import AppKit

/// A reliable, growing multiline text input backed directly by NSTextView.
///
/// Why this exists: SwiftUI's `TextField(text:axis:.vertical)` has a known
/// macOS bug where the field renders and can be clicked, but never properly
/// becomes first responder for keyboard input in some window/view hierarchy
/// configurations (mouse-driven controls like List/sidebar selection keep
/// working since AppKit handles those via mouseDown hit-testing regardless of
/// key-window state, while text entry specifically needs a real first
/// responder — which the SwiftUI TextField sometimes fails to claim). Wrapping
/// NSTextView directly sidesteps that bug entirely and is the same approach
/// professional macOS chat/editor apps use for growing input fields.
///
/// `measuredHeight` is reported back out via binding as the text content's
/// real intrinsic height — without this, NSScrollView has no defined
/// intrinsic size and defaults to expanding to fill whatever space its
/// parent HStack/VStack offers, which is what made the composer look
/// oversized/disproportionate even with little or no text typed.
struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    var onSubmit: () -> Void
    var minHeight: CGFloat = 20
    var maxHeight: CGFloat = 140

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13.5)
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        context.coordinator.recalculateHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.recalculateHeight()
        }
        // Coordinator is created once (makeCoordinator), but onSubmit is a
        // closure that captures whatever `sessionId`/state was live at
        // creation time — without refreshing it here, every Enter keypress
        // would keep calling the ORIGINAL closure from the very first render
        // forever. That's exactly what caused every message to create a new
        // chat: the very first render happened while sessionId was still nil
        // (fresh "New Chat" state), so the stale closure kept passing nil as
        // the target session on every subsequent send, no matter which chat
        // was actually showing on screen.
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, measuredHeight: $measuredHeight, onSubmit: onSubmit, minHeight: minHeight, maxHeight: maxHeight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var measuredHeight: Binding<CGFloat>
        var onSubmit: () -> Void
        let minHeight: CGFloat
        let maxHeight: CGFloat
        weak var textView: NSTextView?

        init(text: Binding<String>, measuredHeight: Binding<CGFloat>, onSubmit: @escaping () -> Void, minHeight: CGFloat, maxHeight: CGFloat) {
            self.text = text
            self.measuredHeight = measuredHeight
            self.onSubmit = onSubmit
            self.minHeight = minHeight
            self.maxHeight = maxHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            recalculateHeight()
        }

        /// Measures the text container's actual used height (i.e. how tall
        /// the current text content really is) and clamps it into
        /// [minHeight, maxHeight] — this is the real fix for the
        /// disproportionate box, since without an explicit measured height
        /// SwiftUI had nothing correct to size the frame against.
        func recalculateHeight() {
            guard let textView else { return }
            guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
            let clamped = max(minHeight, min(usedHeight, maxHeight))
            if abs(measuredHeight.wrappedValue - clamped) > 0.5 {
                DispatchQueue.main.async {
                    self.measuredHeight.wrappedValue = clamped
                }
            }
        }

        // Enter sends the message; Shift+Enter inserts a real newline.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let event = NSApp.currentEvent
                if event?.modifierFlags.contains(.shift) == true {
                    return false // let the newline insert normally
                }
                onSubmit()
                return true
            }
            return false
        }
    }
}
