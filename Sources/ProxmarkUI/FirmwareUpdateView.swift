import ProxmarkKit
import SwiftUI

/// Firmware changes get their own focused flow, separate from scan and write.
/// The user must confirm the hardware target before a flash can start.
struct FirmwareUpdateView: View {
    @EnvironmentObject var app: AppModel
    let sheet: FirmwareUpdateSheet
    @State private var selectedTarget: Pm3Firmware.Target?
    @State private var confirmedTarget = false
    @State private var choosingManually = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IconTile(systemName: "externaldrive", tint: Theme.accent, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sheet == .confirmation ? "Update reader firmware" : "Firmware update")
                        .font(Theme.sans(.semibold, 20))
                        .foregroundStyle(Theme.ink)
                    Text(sheet == .confirmation ? "Match the reader to the bundled client" : statusLine)
                        .font(Theme.sans(.regular, 12.5))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
            }

            if sheet == .confirmation {
                confirmation
            } else {
                progress
            }
        }
        .padding(24)
        .frame(width: 550)
        .background(Theme.canvas)
        .interactiveDismissDisabled(app.firmwareUpdatePhase.isActive)
        .onAppear {
            // Automatic when we can be sure; otherwise the user must choose.
            if selectedTarget == nil { selectedTarget = remembered }
        }
    }

    /// The model learned from this reader's last matching-firmware connection.
    private var remembered: Pm3Firmware.Target? {
        ReaderMemory.demoOverride ?? ReaderMemory.rememberedTarget()
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let remembered, !choosingManually {
                DetectedModelCard(target: remembered) {
                    withAnimation(.easeOut(duration: 0.15)) { choosingManually = true }
                }
            } else {
                Callout(
                    systemName: "questionmark.circle",
                    tint: Theme.accent,
                    title: "Which reader do you have?",
                    message: "The firmware mismatch blocks automatic detection, and both models look the same over USB. Pick the one that matches your board."
                )
                HStack(spacing: 10) {
                    ForEach(Pm3Firmware.Target.allCases, id: \.self) { target in
                        ModelOptionCard(
                            target: target,
                            selected: selectedTarget == target,
                            detected: remembered == target
                        ) {
                            selectedTarget = target
                            confirmedTarget = false
                        }
                    }
                }
                if let remembered, let selectedTarget, selectedTarget != remembered {
                    Label("This reader last connected as a \(remembered.displayName). Flashing \(selectedTarget.displayName) firmware onto it can leave it unusable.", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.sans(.medium, 12))
                        .foregroundStyle(Theme.bad)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Not sure? The model name is printed on the circuit board.")
                        .font(Theme.sans(.regular, 11.5))
                        .foregroundStyle(Theme.secondary)
                }
            }

            Card {
                SectionTitle(text: "What will happen")
                DetailRow(label: "Reader", value: app.selectedPort.map(shortPort) ?? "No reader connected")
                DetailRow(label: "Model", value: selectedTarget?.displayName ?? "Choose above", monospace: false)
                DetailRow(label: "Image", value: selectedTarget.map { "\($0.rawValue)/fullimage.elf" } ?? "fullimage.elf")
                DetailRow(label: "Bootloader", value: "Will not be changed", monospace: false)
            }

            Text("The flasher normally enters bootloader mode automatically. If prompted, press and hold the reader button during its restart. If the reader does not reappear, reconnect it while holding the button. Once writing starts, do not unplug it.")
                .font(Theme.sans(.regular, 12.5))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(selectedTarget.map { "I've checked that my reader is a \($0.displayName)" } ?? "Choose your reader model first", isOn: $confirmedTarget)
                .toggleStyle(.checkbox)
                .font(Theme.sans(.medium, 12.5))
                .disabled(selectedTarget == nil)

            if let reason = app.firmwareUpdateUnavailableReason(for: selectedTarget) {
                Text(reason)
                    .font(Theme.sans(.regular, 12.5))
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { app.firmwareUpdateSheet = nil }
                    .buttonStyle(PillButtonStyle(filled: false))
                Button("Update firmware") {
                    Task { await app.startFirmwareUpdate(hardwareConfirmed: confirmedTarget, target: selectedTarget) }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!confirmedTarget || !app.canUpdateFirmware(for: selectedTarget))
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 16) {
            Callout(
                systemName: statusIcon,
                tint: statusColor,
                title: statusTitle,
                message: statusMessage
            )

            if app.firmwareUpdatePhase.isActive {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activeInstruction)
                        .font(Theme.sans(.medium, 12))
                        .foregroundStyle(Theme.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                SectionTitle(text: "Flasher log")
                ScrollView {
                    Text(app.firmwareUpdateLog.isEmpty ? "Waiting for flasher output…" : app.firmwareUpdateLog.joined(separator: "\n"))
                        .font(Theme.mono(.regular, 10.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 190)
                .background(Theme.console, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack {
                Spacer()
                if case .failed = app.firmwareUpdatePhase {
                    Button("Review and retry") { app.showFirmwareUpdate() }
                        .buttonStyle(PillButtonStyle(filled: false))
                }
                Button("Done") { app.firmwareUpdateSheet = nil }
                    .buttonStyle(PillButtonStyle())
                    .disabled(app.firmwareUpdatePhase.isActive)
            }
        }
    }

    private var statusLine: String {
        switch app.firmwareUpdatePhase {
        case .ready: return "Ready to update"
        case .connecting: return "Preparing the reader and image"
        case .waitingForBootloader: return "Waiting for bootloader mode"
        case .flashing: return "Writing application firmware"
        case .reconnecting: return "Checking the reader connection"
        case .complete: return "Reader and client match"
        case .failed: return "Update needs attention"
        }
    }

    private var statusTitle: String {
        switch app.firmwareUpdatePhase {
        case .ready: return "Preparing update"
        case .connecting: return "Connecting to the reader"
        case .waitingForBootloader: return "Hold the reader button"
        case .flashing: return "Updating the reader"
        case .reconnecting: return "Firmware written, reconnecting"
        case .complete: return "Firmware update complete"
        case .failed: return "Firmware update did not complete"
        }
    }

    private var statusMessage: String {
        switch app.firmwareUpdatePhase {
        case .ready: return "The flasher is starting."
        case .connecting: return "The flasher is checking the image and entering bootloader mode."
        case .waitingForBootloader: return "Press and hold the reader button now. If it does not reappear, reconnect it while holding the button."
        case .flashing: return "The bundled full image is being written. Keep the reader connected."
        case .reconnecting: return "Checking that the updated reader speaks the client's protocol."
        case .complete: return "The reader responded with a matching firmware protocol."
        case .failed(let reason): return reason
        }
    }

    private var statusIcon: String {
        switch app.firmwareUpdatePhase {
        case .complete: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch app.firmwareUpdatePhase {
        case .complete: return Theme.good
        case .failed: return Theme.bad
        default: return Theme.accent
        }
    }

    private var activeInstruction: String {
        switch app.firmwareUpdatePhase {
        case .waitingForBootloader: return "Hold the button until the reader reconnects."
        case .flashing: return "Do not unplug the reader while firmware is being written."
        case .reconnecting: return "The write finished. Checking the reader's protocol."
        default: return "Keep the reader connected while the flasher prepares."
        }
    }
}

/// The model we already know, shown instead of a question.
private struct DetectedModelCard: View {
    let target: Pm3Firmware.Target
    let change: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            BoardSketch(target: target, selected: true)
                .frame(width: 74, height: 50)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(target.displayName)
                        .font(Theme.sans(.semibold, 14))
                        .foregroundStyle(Theme.ink)
                    Label("Detected", systemImage: "checkmark.seal.fill")
                        .font(Theme.sans(.semibold, 10.5))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .foregroundStyle(Theme.good)
                        .background(Theme.good.opacity(0.13), in: Capsule())
                }
                Text("Identified when this reader last connected with matching firmware.")
                    .font(Theme.sans(.regular, 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Change…", action: change)
                .buttonStyle(PillButtonStyle(filled: false))
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.good.opacity(0.35)))
    }
}

/// One selectable reader model, with a sketch and the cues that tell them apart.
private struct ModelOptionCard: View {
    let target: Pm3Firmware.Target
    let selected: Bool
    let detected: Bool
    let action: () -> Void

    private var hint: String {
        switch target {
        case .easy: return "One board with the antennas printed around its edge. Often bare or in a clear case."
        case .rdv4: return "Small main board with a separate snap-on antenna. Usually labeled RDV4."
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    BoardSketch(target: target, selected: selected)
                        .frame(height: 78)
                        .frame(maxWidth: .infinity)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selected ? Theme.accent : Theme.tertiary)
                        .padding(7)
                }
                HStack(spacing: 6) {
                    Text(target.displayName)
                        .font(Theme.sans(.semibold, 13))
                        .foregroundStyle(Theme.ink)
                    if detected {
                        Text("Last seen")
                            .font(Theme.sans(.semibold, 10))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(Theme.good)
                            .background(Theme.good.opacity(0.13), in: Capsule())
                    }
                }
                Text(hint)
                    .font(Theme.sans(.regular, 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .accessibilityLabel(target.displayName)
        .accessibilityHint(hint)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A schematic of each board, enough to tell them apart at a glance: the Easy
/// is one wide board ringed by its antenna; the RDV4 is a compact board with a
/// separate antenna plate.
private struct BoardSketch: View {
    let target: Pm3Firmware.Target
    let selected: Bool

    var body: some View {
        let pcb = selected ? Theme.accent : Theme.secondary
        Canvas { ctx, size in
            // Drawn in a 120x62 design space, scaled to fit whatever frame it gets.
            let s = min(size.width / 120, size.height / 62)
            ctx.translateBy(x: (size.width - 120 * s) / 2, y: (size.height - 62 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            let w: CGFloat = 120, h: CGFloat = 62
            switch target {
            case .easy:
                let board = CGRect(x: w * 0.5 - 52, y: h * 0.5 - 26, width: 104, height: 52)
                ctx.fill(Path(roundedRect: board, cornerRadius: 6), with: .color(pcb.opacity(0.16)))
                ctx.stroke(Path(roundedRect: board, cornerRadius: 6), with: .color(pcb.opacity(0.7)), lineWidth: 1.5)
                // antenna trace around the edge
                ctx.stroke(Path(roundedRect: board.insetBy(dx: 5, dy: 5), cornerRadius: 3), with: .color(pcb.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                // chip + USB
                ctx.fill(Path(roundedRect: CGRect(x: board.midX - 9, y: board.midY - 8, width: 18, height: 16), cornerRadius: 2), with: .color(pcb.opacity(0.75)))
                ctx.fill(Path(CGRect(x: board.minX - 5, y: board.midY - 5, width: 6, height: 10)), with: .color(pcb.opacity(0.6)))
            case .rdv4:
                let board = CGRect(x: w * 0.5 - 46, y: h * 0.5 - 20, width: 46, height: 40)
                let antenna = CGRect(x: board.maxX + 6, y: h * 0.5 - 26, width: 46, height: 52)
                ctx.fill(Path(roundedRect: board, cornerRadius: 5), with: .color(pcb.opacity(0.16)))
                ctx.stroke(Path(roundedRect: board, cornerRadius: 5), with: .color(pcb.opacity(0.7)), lineWidth: 1.5)
                ctx.fill(Path(roundedRect: CGRect(x: board.midX - 8, y: board.midY - 7, width: 16, height: 14), cornerRadius: 2), with: .color(pcb.opacity(0.75)))
                ctx.fill(Path(CGRect(x: board.minX - 5, y: board.midY - 5, width: 6, height: 10)), with: .color(pcb.opacity(0.6)))
                // separate antenna plate with coil rings
                ctx.stroke(Path(roundedRect: antenna, cornerRadius: 5), with: .color(pcb.opacity(0.7)), lineWidth: 1.5)
                for i in 0..<3 {
                    let r = antenna.insetBy(dx: 6 + CGFloat(i) * 5, dy: 6 + CGFloat(i) * 5)
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(pcb.opacity(0.5)), lineWidth: 1)
                }
                // connector between them
                ctx.stroke(Path { p in p.move(to: CGPoint(x: board.maxX, y: board.midY)); p.addLine(to: CGPoint(x: antenna.minX, y: board.midY)) }, with: .color(pcb.opacity(0.6)), lineWidth: 2)
            }
        }
        .accessibilityHidden(true)
    }
}
