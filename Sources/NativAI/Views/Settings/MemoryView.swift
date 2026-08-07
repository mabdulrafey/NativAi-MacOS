/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

/// Shows and manages everything the app has remembered about the user.
///
/// This view is a requirement of the feature, not an accessory to it. The main
/// complaint about ChatGPT's memory is not knowing what it kept; an offline-first
/// app that quietly accumulated personal facts with no way to inspect them would
/// be worse, because the whole premise is that your data stays yours. So: every
/// fact is listed, individually deletable, and the feature is off until asked for.
struct MemoryView: View {
    /// Injected rather than reached via `MemoryStore.shared` in a property
    /// initialiser.
    ///
    /// A default value like `@ObservedObject private var store = MemoryStore.shared`
    /// forces the `@MainActor` singleton to initialise during *view value*
    /// construction — which SwiftUI performs while assembling the view tree, not
    /// necessarily inside an established main-actor render pass. That first
    /// access runs `init()` → `load()` → file I/O and JSON decoding, and when it
    /// fails there the failure takes down the enclosing `NavigationSplitView`
    /// body rather than surfacing as a crash, which is exactly the "entire window
    /// goes blank, including the sidebar" symptom.
    ///
    /// Taking it as a parameter defers that access to `MainShellView.detailView`,
    /// which is unambiguously on the main actor and already rendering. It also
    /// matches how every other view in this app receives shared state — the
    /// established pattern here is explicit injection, not implicit singletons.
    @ObservedObject var store: MemoryStore
    @EnvironmentObject private var appState: AppState

    @State private var showingClearConfirmation = false
    @State private var newFactText: String = ""
    @State private var newFactKind: MemoryFact.Kind = .preference

    private var embeddingModelInstalled: Bool {
        appState.installedModels.contains { model in
            EmbeddingService.preferredModels.contains {
                model.name == $0 || model.name.hasPrefix("\($0):")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !store.isEnabled {
                disabledState
            } else if store.facts.isEmpty {
                emptyState
            } else {
                factList
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory")
                        .font(.title2.weight(.semibold))
                    Text("Facts remembered across all your chats. Stored only on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Bound through an explicit action rather than `$store.isEnabled`.
                // A direct binding writes the @Published property mid-render,
                // which SwiftUI resolves by discarding the enclosing body.
                Toggle("", isOn: Binding(
                    get: { store.isEnabled },
                    set: { store.setEnabled($0) }
                ))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if store.isEnabled {
                HStack(spacing: 6) {
                    Image(systemName: embeddingModelInstalled ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(embeddingModelInstalled ? .green : .secondary)
                    // Retrieval works without an embedding model, just less
                    // precisely — so this is informational, not a blocker.
                    Text(embeddingModelInstalled
                         ? "Semantic recall active."
                         : "Install “nomic-embed-text” (0.2 GB) from Browse Models for smarter recall.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }

    private var disabledState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Memory is off")
                .font(.headline)
            Text("""
            When on, NativAI notes durable facts you mention — your projects, \
            the people you work with, how you like answers — and uses them in \
            later chats.

            Only what you type is ever remembered. Attachments and documents \
            are never stored, and nothing leaves this Mac.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Nothing remembered yet")
                .font(.headline)
            Text("Mention something about yourself or your work and it'll appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var factList: some View {
        VStack(spacing: 0) {
            addFactComposer
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(MemoryFact.Kind.allCases, id: \.self) { kind in
                        let matching = store.facts.filter { $0.kind == kind }
                        if !matching.isEmpty {
                            Text(kind.displayName.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)

                            ForEach(matching) { fact in
                                row(for: fact)
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text("\(store.facts.count) remembered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Forget Everything", role: .destructive) {
                    showingClearConfirmation = true
                }
                .controlSize(.small)
            }
            .padding(12)
        }
        .confirmationDialog(
            "Forget all \(store.facts.count) remembered facts?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget Everything", role: .destructive) { store.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Your chats are not affected.")
        }
    }

    private func row(for fact: MemoryFact) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: fact.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(fact.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button {
                store.delete(id: fact.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Forget this")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var addFactComposer: some View {
        HStack(spacing: 8) {
            Picker("", selection: $newFactKind) {
                ForEach(MemoryFact.Kind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)

            TextField("Add a fact manually (e.g. The user prefers concise code)", text: $newFactText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addNewFact)

            Button("Add") {
                addNewFact()
            }
            .controlSize(.small)
            .disabled(newFactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func addNewFact() {
        let text = newFactText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let fact = MemoryFact(text: text, kind: newFactKind)
        store.add(fact)
        newFactText = ""
    }
}
