import AppKit
import SwiftUI

struct TerminalProjectImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: TerminalWorkspace
    @State private var candidates: [TerminalProjectImportCandidate] = []
    @State private var selected: Set<String> = []
    @State private var source: TerminalProjectImportSource?
    @State private var query = ""
    @State private var scanning = true
    @State private var skipped = 0
    @State private var truncated = false
    @State private var error: String?

    private var imported: Set<String> {
        Set(workspace.projectLayout.projects.compactMap { $0.directory.flatMap(TerminalProjectImportScanner.canonicalDirectory) })
    }
    private var visible: [TerminalProjectImportCandidate] {
        candidates.filter {
            (source.map($0.sources.contains) ?? true) && (query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query) || $0.directory.localizedCaseInsensitiveContains(query))
        }
    }
    private var selectedCandidates: [TerminalProjectImportCandidate] {
        candidates.filter { selected.contains($0.id) && !imported.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("project.import.title")).font(.headline)
            Text(L10n.string("project.import.description")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker(L10n.string("project.import.source"), selection: $source) {
                    Text(L10n.string("project.import.all_sources")).tag(Optional<TerminalProjectImportSource>.none)
                    ForEach(TerminalProjectImportSource.allCases) { item in Text(item.name).tag(Optional(item)) }
                }.frame(width: 180)
                TextField(L10n.string("project.import.search"), text: $query)
                    .accessibilityIdentifier("project-import-search")
            }
            if scanning {
                ProgressView(L10n.string("project.import.scanning")).frame(maxWidth: .infinity, minHeight: 250)
            } else {
                HStack {
                    Text(L10n.format("project.import.found", visible.count)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string("project.import.select_visible")) {
                        selected.formUnion(visible.filter { !imported.contains($0.id) }.map(\.id))
                    }.disabled(visible.allSatisfy { imported.contains($0.id) })
                    Button(L10n.string("project.import.clear_selection")) { selected.removeAll() }.disabled(selected.isEmpty)
                }
                List {
                    if visible.isEmpty { Text(L10n.string("project.import.empty")).foregroundStyle(.secondary) }
                    ForEach(visible) { candidate in candidateRow(candidate) }
                }.frame(minHeight: 250)
                if skipped > 0 { Text(L10n.format("project.import.skipped", skipped)).font(.caption).foregroundStyle(.secondary) }
                if truncated { Text(L10n.string("project.import.truncated")).font(.caption).foregroundStyle(.secondary) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L10n.string("project.import.choose_folder")) { chooseFolder() }.disabled(scanning)
                Spacer()
                Button(L10n.string("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.format("project.import.confirm", selectedCandidates.count)) { importSelection() }
                    .keyboardShortcut(.defaultAction).disabled(scanning || selectedCandidates.isEmpty)
                    .accessibilityIdentifier("project-import-confirm")
            }
        }
        .padding(20).frame(width: 620, height: 510)
        .task {
            let value = await Task.detached(priority: .userInitiated) {
                var scanner = TerminalProjectImportScanner()
                return scanner.scan()
            }.value
            guard !Task.isCancelled else { return }
            candidates = value.candidates; skipped = value.skippedRecords; truncated = value.truncated; scanning = false
        }
    }

    private func candidateRow(_ candidate: TerminalProjectImportCandidate) -> some View {
        Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: {
            if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
        })) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(candidate.name).lineLimit(1)
                    Spacer()
                    if imported.contains(candidate.id) { Text(L10n.string("project.import.already_added")).foregroundStyle(.secondary) }
                }
                Text(candidate.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(candidate.sources.sorted { $0.rawValue < $1.rawValue }.map(\.name).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .disabled(imported.contains(candidate.id))
        .accessibilityIdentifier("project-import-candidate-\(candidate.directory)")
        .help(candidate.directory)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        source = nil; query = ""
        for url in panel.urls {
            guard let path = TerminalProjectImportScanner.canonicalDirectory(url.path) else { continue }
            if !candidates.contains(where: { $0.id == path }) {
                candidates.append(.init(directory: path, name: url.lastPathComponent, sources: []))
            }
            if !imported.contains(path) { selected.insert(path) }
        }
    }

    private func importSelection() {
        do {
            let added = try workspace.importProjects(selectedCandidates)
            guard added > 0 else { error = L10n.string("project.import.none_added"); return }
            dismiss()
        }
        catch { self.error = L10n.string("project.invalid_layout") }
    }
}
