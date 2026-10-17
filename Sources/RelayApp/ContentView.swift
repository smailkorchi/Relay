import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import RelayCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var drop = DropInteraction()

    var body: some View {
        VStack(spacing: 0) {
            if model.page.isSetup { stepIndicator.padding(.top, 20) }
            ScrollView {
                pageContent
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.top, model.page.isSetup ? 32 : 48)
                    .padding(.bottom, 24)
                    .id(model.page)
                    .transition(pageTransition)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .background { RelayWindowBackground().ignoresSafeArea() }
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 1), value: model.page)
        .frame(minWidth: 700, minHeight: 590)
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let offset: CGFloat = model.navigationDirection >= 0 ? 18 : -18
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: offset)),
                           removal: .opacity.combined(with: .offset(x: -offset)))
    }

    private var stepIndicator: some View {
        HStack(spacing: 25) {
            ForEach([RelayPage.direction, .files, .destination, .review], id: \.rawValue) { page in
                Button { model.showSetupStep(page) } label: {
                    VStack(spacing: 7) {
                        Text(page.title)
                            .font(.system(size: 11, weight: model.page == page ? .semibold : .regular))
                            .foregroundStyle(model.page == page ? Color.primary : Color.secondary)
                        Capsule()
                            .fill(model.page == page ? Color.accentColor : Color.primary.opacity(page.stepNumber < model.setupStep ? 0.2 : 0.08))
                            .frame(width: 30, height: 3)
                    }
                }
                .buttonStyle(.plain)
                .disabled(page.stepNumber > model.setupStep)
                .accessibilityLabel("Step \(page.stepNumber) of 4: \(page.title)")
                .accessibilityAddTraits(model.page == page ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case .direction: directionPage
        case .files: filesPage
        case .destination: destinationPage
        case .review: reviewPage
        case .progress: progressPage
        case .success: successPage
        case .recovery: recoveryPage
        }
    }

    private var directionPage: some View {
        VStack(spacing: 34) {
            RelayPageHeading(title: "Where are your files going?", subtitle: "Choose the direction of your transfer.")
            directionChoices
            Text("Copied carefully. Verified automatically.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.top, 30)
    }

    @ViewBuilder private var directionChoices: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 14) { directionTiles }
        } else {
            directionTiles
        }
    }

    private var directionTiles: some View {
        HStack(spacing: 18) {
            directionChoice(.toDrive, subtitle: "To an external drive")
            directionChoice(.toMac, subtitle: "To a folder on your Mac")
        }
    }

    private func directionChoice(_ direction: TransferDirection, subtitle: String) -> some View {
        let selected = model.direction == direction
        return Button { model.changeDirection(direction) } label: {
            VStack(spacing: 27) {
                RelayDevicePair(toDrive: direction == .toDrive, size: 34)
                VStack(spacing: 6) {
                    Text(direction.title).font(.system(size: 15, weight: .semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.3))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 27)
            .modifier(RelayDirectionSurface(selected: selected))
        }
        .buttonStyle(RelayChoiceStyle())
        .accessibilityLabel("\(direction.title). \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var filesPage: some View {
        VStack(spacing: 23) {
            RelayHeroSymbol(symbol: "doc.on.doc")
            RelayPageHeading(title: "Choose your files.", subtitle: model.direction == .toDrive
                ? "Drop a file or a batch from your Mac." : "Drop a file or a batch from your external drive.")
            VStack(spacing: 0) {
                if model.files.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "plus").font(.system(size: 22, weight: .ultraLight)).foregroundStyle(.tertiary)
                        Text(drop.filesTargeted ? "Release to add files" : "Drop files here")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Choose Files…") { model.chooseFiles() }.buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity).frame(height: 165)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.files.enumerated()), id: \.element.id) { index, file in
                                fileRow(file)
                                if index < model.files.count - 1 { Divider().padding(.leading, 49) }
                            }
                        }
                    }
                    .frame(height: min(180, max(104, CGFloat(model.files.count) * 52)))
                    Divider()
                    HStack {
                        Text("\(fileCount) · \(byteString(model.totalBytes))").foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { model.clearFiles() }.buttonStyle(.borderless)
                        Button("Add Files…") { model.chooseFiles() }.buttonStyle(.borderless)
                    }
                    .font(.caption).padding(12)
                }
            }
            .modifier(QuietWell(targeted: drop.filesTargeted))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $drop.filesTargeted) { acceptDrop($0, destination: false) }
            setupError
        }
    }

    private var destinationPage: some View {
        VStack(spacing: 23) {
            RelayHeroSymbol(symbol: model.direction == .toDrive ? "externaldrive" : "folder")
            RelayPageHeading(title: "Give them a destination.", subtitle: model.direction == .toDrive
                ? "Choose a connected drive, or a folder on it." : "Choose the folder where your files will arrive.")
            VStack(spacing: 17) {
                HStack(spacing: 14) {
                    Image(systemName: model.direction == .toDrive ? "externaldrive.fill" : "folder.fill")
                        .font(.system(size: 27, weight: .light)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.destination == nil ? "Drop a destination folder here" : model.destinationName)
                            .font(.callout.weight(.medium)).lineLimit(1)
                        if let destination = model.destination {
                            Text(destination.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(destination.path)
                        } else {
                            Text("Or choose one in Finder").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    destinationPicker
                }
                .padding(18)
                .modifier(QuietWell(targeted: drop.destinationTargeted))
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $drop.destinationTargeted) { acceptDrop($0, destination: true) }
                speedPanel
            }
            setupError
        }
    }

    @ViewBuilder private var destinationPicker: some View {
        if model.direction == .toDrive {
            Menu(model.destination == nil ? "Choose…" : "Change…") {
                ForEach(model.volumes) { volume in
                    Button { model.selectDestination(volume.url) } label: {
                        Label("\(volume.name) — \(byteString(volume.availableBytes)) available", systemImage: "externaldrive")
                    }
                    .disabled(volume.isReadOnly)
                }
                if !model.volumes.isEmpty { Divider() }
                Button("Choose Folder…") { model.chooseDestination() }
                Button("Refresh Drives") { model.refreshVolumes() }
            }
            .menuStyle(.borderlessButton).fixedSize()
        } else {
            Button(model.destination == nil ? "Choose…" : "Change…") { model.chooseDestination() }
                .buttonStyle(.borderless)
        }
    }

    private var speedPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 15) {
                if model.isBenchmarking {
                    ProgressView().controlSize(.mini)
                    Text(model.benchmarkStatus).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Cancel Test") { model.cancelBenchmark() }.buttonStyle(.borderless)
                } else if let benchmark = model.benchmark {
                    rateLabel("Read", symbol: "arrow.down", value: benchmark.readBytesPerSecond)
                    rateLabel("Write", symbol: "arrow.up", value: benchmark.writeBytesPerSecond)
                    Spacer(minLength: 0)
                    Button("Test Again") { model.testSpeed() }.buttonStyle(.borderless)
                } else if model.destination != nil {
                    Text(model.benchmarkError == nil ? "Speed test cancelled" : "Speed unavailable").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Test Speed") { model.testSpeed() }.buttonStyle(.borderless)
                }
            }
            .font(.caption)
            if let error = model.benchmarkError {
                Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 3)
    }

    private var reviewPage: some View {
        VStack(spacing: 27) {
            RelayDevicePair(toDrive: model.direction == .toDrive, size: 38).padding(.top, 4)
            RelayPageHeading(title: "Ready when you are.", subtitle: "\(fileCount) · \(byteString(model.totalBytes))")
            VStack(spacing: 0) {
                reviewRow(title: "From", value: model.direction == .toDrive ? "Your Mac" : "Your external drive", symbol: model.direction == .toDrive ? "desktopcomputer" : "externaldrive")
                Divider().padding(.leading, 48)
                reviewRow(title: "To", value: model.destinationName, symbol: model.direction == .toDrive ? "externaldrive" : "folder")
            }
            .modifier(QuietWell())
            VStack(alignment: .leading, spacing: 12) {
                Text("After the transfer").font(.callout.weight(.medium))
                Picker("After the transfer", selection: $model.disposition) {
                    Text("Keep originals").tag(SourceDisposition.keep)
                    Text("Move originals to Trash").tag(SourceDisposition.trashAfterVerification)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .disabled(model.isResuming)
                Text(model.disposition == .keep ? "The original files stay where they are." : "Originals move to Trash only after the entire batch is verified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Every copy is read back and checked before it’s complete.")
                .font(.caption).foregroundStyle(.tertiary)
            setupError
        }
    }

    private var progressPage: some View {
        VStack(spacing: 27) {
            RelayDevicePair(toDrive: model.direction == .toDrive, size: 43).padding(.vertical, 12)
            RelayPageHeading(title: progressTitle, subtitle: "\(fileCount) to \(model.destinationName)")
            HStack(spacing: 9) {
                phaseBadge("Copy", symbol: "doc.on.doc", active: model.event?.phase == .copying || model.event?.phase == .flushing)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                phaseBadge("Verify", symbol: "checkmark", active: model.event?.phase == .verifying)
            }
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int((model.event?.fractionCompleted ?? 0) * 100))%")
                        .font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if let remaining = model.estimatedSecondsRemaining, remaining > 0 {
                            Text("About \(durationString(remaining)) remaining")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                ProgressView(value: model.event?.fractionCompleted ?? 0)
                    .accessibilityLabel("Overall transfer and verification progress")
                HStack {
                    Text(model.event?.filename.isEmpty == false ? model.event!.filename : model.statusMessage)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text("\(model.verifiedCount) of \(model.files.count) verified").monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                HStack(spacing: 24) {
                    rateLabel("Read", symbol: "arrow.down", value: model.event?.readBytesPerSecond ?? 0)
                    rateLabel("Write", symbol: "arrow.up", value: model.event?.writeBytesPerSecond ?? 0)
                }
                .font(.caption)
                if let retry = model.retryStatus {
                    Label(retry, systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(durationString(model.elapsedSeconds)) elapsed").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
        }
        .padding(.top, 18)
    }

    private var successPage: some View {
        VStack(spacing: 27) {
            RelayHeroSymbol(symbol: "checkmark", tint: .green).padding(.top, 25)
            RelayPageHeading(title: "All set.", subtitle: "Your files arrived exactly as they left.")
            VStack(spacing: 10) {
                Text("\(model.verifiedCount) \(model.verifiedCount == 1 ? "file" : "files") verified · \(byteString(model.totalBytes))")
                    .font(.system(size: 15, weight: .medium))
                Label(model.destinationName, systemImage: model.direction == .toDrive ? "externaldrive" : "folder")
                    .font(.callout).foregroundStyle(.secondary)
                Text(model.disposition == .keep ? "Originals kept." : "Originals moved to Trash.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 7)
            }
            if model.receiptURL != nil {
                Button("View Verification Receipt") { model.revealReceipt() }.buttonStyle(.borderless).font(.callout)
            }
            if let error = model.errorMessage { inlineError(error) }
        }
    }

    private var recoveryPage: some View {
        VStack(spacing: 23) {
            RelayHeroSymbol(symbol: model.isCancelled ? "pause" : "exclamationmark", tint: model.isCancelled ? .secondary : .orange)
                .padding(.top, 8)
            RelayPageHeading(title: model.failureTitle, subtitle: model.failureAdvice)
            if model.verifiedCount > 0 {
                Label("\(model.verifiedCount) \(model.verifiedCount == 1 ? "file is" : "files are") already verified", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                DisclosureGroup("Details") {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                .font(.caption).padding(.horizontal, 12)
            }
            HStack(spacing: 24) {
                Button("Choose Destination…") { model.editDestination() }
                Button("Edit Files…") { model.editFiles() }
                if model.receiptURL != nil { Button("View Receipt") { model.revealReceipt() } }
            }
            .buttonStyle(.borderless).font(.callout)
        }
    }

    private var footer: some View {
        HStack {
            if model.page.isSetup {
                if model.canGoBack {
                    Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                }
                Spacer()
                RelayPrimaryButton(title: model.page == .review ? "Transfer" : "Continue", enabled: model.canContinue) { model.continueSetup() }
            } else if model.page == .progress {
                Text(model.statusMessage == "Stopping safely…" ? model.statusMessage : "")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel Transfer") { model.cancelTransfer() }
                    .controlSize(.large).disabled(model.statusMessage == "Stopping safely…")
            } else if model.page == .success {
                Button("New Transfer") { model.newTransfer() }.buttonStyle(.borderless)
                Spacer()
                RelayPrimaryButton(title: "Show in Finder") { model.revealDestination() }
            } else {
                Button("Review Transfer") { model.editTransfer() }.buttonStyle(.borderless)
                Spacer()
                if model.retryAvailable {
                    RelayPrimaryButton(title: "Retry Transfer", enabled: model.canRetry) { model.retryTransfer() }
                } else {
                    RelayPrimaryButton(title: "Edit Transfer") { model.editTransfer() }
                }
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 16)
        .padding(.bottom, 26)
    }

    @ViewBuilder private var setupError: some View {
        if let error = model.errorMessage { inlineError(error) }
    }

    private func inlineError(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.dismissError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("Dismiss error")
        }
        .padding(12).background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func fileRow(_ file: QueuedFile) -> some View {
        HStack(spacing: 11) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable().scaledToFit().frame(width: 25, height: 28).accessibilityHidden(true)
            Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle).help(file.url.path)
            Spacer(minLength: 10)
            Text(byteString(file.size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button { model.removeFile(file.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.borderless).accessibilityLabel("Remove \(file.name)")
        }
        .padding(.horizontal, 13).frame(height: 52)
    }

    private func reviewRow(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 19, weight: .light)).foregroundStyle(.secondary).frame(width: 24)
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            Text(value).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func phaseBadge(_ title: String, symbol: String, active: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: active ? .medium : .regular))
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(active ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025), in: Capsule())
    }

    private func rateLabel(_ title: String, symbol: String, value: Double) -> some View {
        Label("\(title) \(rateString(value))", systemImage: symbol)
            .foregroundStyle(.secondary).monospacedDigit().accessibilityElement(children: .combine)
    }

    private var fileCount: String { "\(model.files.count) \(model.files.count == 1 ? "file" : "files")" }
    private var progressTitle: String {
        if model.retryStatus != nil { return "Finding the connection." }
        if model.event?.phase == .verifying { return "Checking every detail." }
        if model.event?.phase == .flushing { return "Saving to disk." }
        if model.event?.phase == .movingOriginals { return "One last thing." }
        return "Your files are on their way."
    }

    private func acceptDrop(_ providers: [NSItemProvider], destination: Bool) -> Bool {
        guard !model.isBusy else { return false }
        let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !candidates.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in candidates {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: item as? URL) }
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            guard !model.isBusy else { return }
            if destination, let url = urls.first { model.selectDestination(url) }
            else if !destination { model.addFiles(urls) }
        }
        return true
    }
}

private struct QuietWell: ViewModifier {
    var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(targeted ? Color.accentColor.opacity(0.05) : Color(nsColor: .controlBackgroundColor).opacity(reduceTransparency ? 1 : 0.42))
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(targeted ? Color.accentColor.opacity(0.8) : Color.primary.opacity(contrast == .increased ? 0.35 : 0.09), lineWidth: targeted ? 1.5 : 0.5))
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: targeted)
    }
}

@MainActor
private final class DropInteraction: ObservableObject {
    @Published var filesTargeted = false
    @Published var destinationTargeted = false
}

private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func rateString(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond > 0 else { return "—" }
    if bytesPerSecond >= 1_000_000_000 { return String(format: "%.2f GB/s", bytesPerSecond / 1_000_000_000) }
    return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
}

private func durationString(_ seconds: TimeInterval) -> String {
    let seconds = max(0, Int(seconds.rounded()))
    if seconds >= 3600 { return "\(seconds / 3600) hr \((seconds % 3600) / 60) min" }
    if seconds >= 60 { return "\(seconds / 60) min \(seconds % 60) sec" }
    return "\(seconds) sec"
}
