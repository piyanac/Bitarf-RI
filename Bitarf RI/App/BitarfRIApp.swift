//
//  BitarfRIApp.swift
//  Bitarf RI
//

import SwiftUI

@main
struct BitarfRIApp: App {

    @StateObject private var editor = EditorState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 系統設定裡的 Settings.bundle 只讀得到 UserDefaults，讀不到 app 的
        // Info.plist，所以版本得在這裡抄過去一份。
        UserDefaults.standard.set(AppInfo.versionString, forKey: "version_preference")
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(editor)
        }
        .onChange(of: scenePhase) { _, phase in
            // Autosave is debounced, so a backgrounding app could otherwise lose
            // the last second and a half of work.
            if phase != .active { editor.save() }
        }
    }
}

/// Owns the two halves of the app: the browser, which is a tab bar of small
/// navigation stacks, and the editor, which covers it.
///
/// The editor is presented rather than pushed. Opening a document is not
/// travelling deeper into a list — it is the app changing job — and the upward
/// cover says that where a sideways push said "one level down from 範本".
struct AppShell: View {

    @EnvironmentObject private var editor: EditorState
    @AppStorage(LaunchBehaviour.storageKey) private var launchBehaviour = LaunchBehaviour.newDocument

    @State private var showsEditor = false
    /// The library row the editor was opened from, if any. Drives the zoom
    /// transition: a new document has no source to grow out of, so it keeps the
    /// plain upward cover.
    @State private var zoomSource: UUID?
    @Namespace private var zoomNamespace
    @State private var hasLaunched = false
    @State private var notice: String?
    @State private var reloadToken = 0

    private let library = DocumentLibrary()

    var body: some View {
        DocumentBrowserView(
            notice: $notice,
            reloadToken: reloadToken,
            zoomNamespace: zoomNamespace,
            open: { document, entry in
                // Only a template hands over its identity for 「更新範本」, and
                // only an unfinished row is a row this work can go back to.
                // History opens as a plain copy: a record of what came out of
                // the printer stops being a record if editing can rewrite it.
                editor.open(
                    document,
                    sourceTemplateID: entry?.kind == .template ? entry?.id : nil,
                    recoveredID: entry?.kind == .recovered ? entry?.id : nil
                )
                zoomSource = entry?.id
                showsEditor = true
            },
            openNew: {
                editor.newDocument()
                zoomSource = nil
                showsEditor = true
            },
            openFile: { url in
                // A file from outside has no library row behind it, so it opens
                // the way a new document does: plain cover, nothing to grow out
                // of, and nothing to write back to on the way out. Failures land
                // in the browser's notice instead of behind a cover the user
                // never wanted.
                guard editor.importDocument(from: url) else {
                    notice = editor.statusMessage
                    return
                }
                zoomSource = nil
                showsEditor = true
            }
        )
        .fullScreenCover(isPresented: $showsEditor) {
            let editorView = NavigationStack {
                RootView(onLeave: leaveEditor)
            }
            .environmentObject(editor)
            .interactiveDismissDisabled()

            if let zoomSource {
                editorView.navigationTransition(.zoom(sourceID: zoomSource, in: zoomNamespace))
            } else {
                editorView
            }
        }
        .task {
            guard !hasLaunched else { return }
            hasLaunched = true
            launch()
        }
    }

    // MARK: - Launch

    /// Decide what the app opens on, and make sure nothing was lost on the way
    /// in. Runs once per process.
    private func launch() {
        library.migrateLegacyAutosaveIfNeeded()

        let state = library.scratchState()
        let scratch = library.scratchDocument()

        // The upgrade case: the document the user had open before the library
        // existed is handed straight back, rather than turning into a row in a
        // list they have never seen.
        if state.resumesOnNextLaunch, let scratch {
            editor.resume(scratch, state: DocumentLibrary.ScratchState(
                isCommitted: state.isCommitted,
                hasBeenEdited: state.hasBeenEdited,
                sourceTemplateID: state.sourceTemplateID
            ))
            showsEditor = true
            return
        }

        // Scratch that survived to a new launch means the app never got a clean
        // exit — a crash, or the system reclaiming it. The work goes straight
        // back on screen: being dropped on a blank canvas and told to go looking
        // in a list is not what anyone means by "it crashed".
        if let scratch, state.hasBeenEdited, !state.isCommitted, scratch.hasPrintableContent {
            if state.uncleanLaunches < 1 {
                var resumed = state
                resumed.uncleanLaunches += 1
                try? library.writeScratch(scratch, state: resumed)
                editor.resume(scratch, state: resumed)
                showsEditor = true
                editor.statusMessage = "已還原上次未完成的內容。"
                return
            }

            // Second unclean launch on the same content: opening it is now the
            // best guess for what is killing the app, so it gets filed instead
            // of reopened and the user lands somewhere that definitely works.
            _ = try? library.saveRecovered(scratch, id: state.recoveredID ?? UUID())
            library.clearScratch()
            editor.open(DocumentDefaults.applied(to: BitarfDocument.starter()))
            if launchBehaviour == .newDocument {
                showsEditor = true
            }
            let message = "開啟文件時反覆當機，已保留在「最近」裡。"
            notice = message
            editor.statusMessage = message
            return
        }

        library.clearScratch()
        editor.open(DocumentDefaults.applied(to: BitarfDocument.starter()))
        if launchBehaviour == .newDocument {
            showsEditor = true
        }
    }

    // MARK: - Leaving the editor

    private func leaveEditor() {
        editor.stashUncommittedWork()
        editor.discardScratch()
        showsEditor = false
        reloadToken &+= 1
    }
}
