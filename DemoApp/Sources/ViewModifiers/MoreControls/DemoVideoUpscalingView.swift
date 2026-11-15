//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Foundation
import StreamVideo
import SwiftUI

struct DemoVideoUpscalingBar: View {
    @ObservedObject private var state: CallState
    @StateObject private var model: DemoVideoUpscalingModel

    init(call: Call) {
        state = call.state
        _model = StateObject(wrappedValue: DemoVideoUpscalingModel(call: call, liveUpdates: true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Video scaler", systemImage: "sparkles.tv")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(scaleLabel)
                    .font(.subheadline.monospacedDigit())
            }

            Picker("Video scaler", selection: Binding<VideoUpscalingConfiguration.Backend?>(
                get: { state.videoUpscalingOverrides.isEmpty ? model.configuration.backend : nil },
                set: { if let backend = $0 { selectBackend(backend) } }
            )) {
                Text("Off").tag(Optional(VideoUpscalingConfiguration.Backend.off))
                Text("VideoToolbox").tag(Optional(VideoUpscalingConfiguration.Backend.videoToolbox))
                Text("MetalFX").tag(Optional(VideoUpscalingConfiguration.Backend.metalFX))
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("videoScalerBackend")

            HStack(spacing: 12) {
                Text("Scale").font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(model.scales.firstIndex(of: model.configuration.scale) ?? 0) },
                        set: { index in
                            let scales = model.scales
                            let index = Int(index.rounded())
                            guard scales.indices.contains(index) else { return }
                            model.configuration.scale = scales[index]
                        }
                    ),
                    in: 0...Double(max(model.scales.count - 1, 1)),
                    step: 1
                )
                .disabled(model.configuration.backend == .off || model.scales.count < 2)
                .accessibilityLabel("Video upscaling factor")
                .accessibilityValue("\(model.configuration.scale, specifier: "%g") times")
                .accessibilityIdentifier("videoScalerScale")
            }

            Text(model.error ?? statusText)
                .font(.caption)
                .foregroundColor(model.error == nil ? .secondary : .red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task(id: inputSizeKey) {
            await model.refreshCapabilities()
            guard !Task.isCancelled else { return }
            selectSupportedScale()
        }
        .onReceive(state.$videoUpscalingDefault) { model.synchronize($0) }
    }

    private var firstStatus: VideoUpscalingStatus? {
        let track = state.videoUpscalingStatuses.keys.sorted {
            ($0.participantSessionID, $0.source.rawValue) < ($1.participantSessionID, $1.source.rawValue)
        }.first
        return track.flatMap { state.videoUpscalingStatuses[$0] }
    }

    private var inputSizeKey: String {
        guard let status = firstStatus else { return "waiting" }
        return "\(status.inputWidth)x\(status.inputHeight)"
    }

    private var statusText: String {
        if !state.videoUpscalingOverrides.isEmpty {
            return "Individual video settings · choose a mode to apply to all."
        }
        if model.configuration.backend == .off { return "Original received video" }
        if model.capabilities?.backends.first(where: {
            $0.backend == model.configuration.backend
        })?.isSupported == false {
            return "This scaler is not available on this device."
        }
        guard let status = firstStatus else { return "Waiting for received video…" }
        if model.scales.isEmpty { return "No supported scale for this video size." }
        guard status.configuration == model.configuration, status.state != .preparing else {
            return "Applying scaler…"
        }
        if status.state == .passthrough { return "Showing original video while scaling is unavailable." }
        return "Received video · \(status.inputWidth)×\(status.inputHeight) → \(status.outputWidth)×\(status.outputHeight)"
    }

    private var scaleLabel: String {
        if !state.videoUpscalingOverrides.isEmpty { return "Custom" }
        if model.configuration.backend == .off { return "Off" }
        return String(format: "%g×", model.configuration.scale)
    }

    private func selectBackend(_ backend: VideoUpscalingConfiguration.Backend) {
        let scales = model.capabilities?.backends.first { $0.backend == backend }?.scaleFactors ?? []
        let scale = scales.min {
            abs($0 - model.configuration.scale) < abs($1 - model.configuration.scale)
        } ?? 2
        model.configuration = .init(backend: backend, scale: scale)
        model.applyToAll()
    }

    private func selectSupportedScale() {
        guard model.configuration.backend != .off,
              !model.scales.contains(model.configuration.scale),
              let scale = model.scales.min(by: {
                  abs($0 - model.configuration.scale) < abs($1 - model.configuration.scale)
              }) else { return }
        model.configuration.scale = scale
    }
}

struct DemoVideoUpscalingView: View {
    @ObservedObject private var state: CallState
    @StateObject private var model: DemoVideoUpscalingModel
    @Environment(\.presentationMode) private var presentationMode

    init(call: Call) {
        state = call.state
        _model = StateObject(wrappedValue: DemoVideoUpscalingModel(call: call))
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Received video")) {
                    Picker("Target", selection: $model.target) {
                        Text("Call default").tag(VideoUpscalingTarget.all)
                        ForEach(state.remoteParticipants, id: \.sessionId) { participant in
                            ForEach(VideoUpscalingTrack.Source.allCases, id: \.self) { source in
                                Text("\(participant.name) · \(source == .camera ? "Camera" : "Screen share")")
                                    .tag(VideoUpscalingTarget.track(.init(
                                        participantSessionID: participant.sessionId, source: source
                                    )))
                            }
                        }
                    }
                    Text(model.target == .all
                        ? "Applies to tracks without an override."
                        : "Reset to use the call default.")
                        .font(.caption)
                    Picker("Backend", selection: Binding(
                        get: { model.configuration.backend },
                        set: { model.configuration = .init(backend: $0) }
                    )) {
                        ForEach(VideoUpscalingConfiguration.Backend.allCases, id: \.self) { backend in
                            Text(title(for: backend)).tag(backend)
                        }
                    }
                    if model.configuration.backend != .off {
                        if model.scales.isEmpty {
                            Text("No supported scales for this input. Refresh after video arrives.")
                                .font(.caption)
                        } else {
                            Picker("Scale", selection: $model.configuration.scale) {
                                ForEach(model.scales, id: \.self) { scale in
                                    Text("\(scale, specifier: "%g")×").tag(scale)
                                }
                            }
                        }
                    }
                    if model.configuration.backend == .metalFX {
                        Picker("Color", selection: $model.configuration.colorMode) {
                            Text("Perceptual").tag(VideoUpscalingConfiguration.ColorMode.perceptual)
                            Text("Linear").tag(VideoUpscalingConfiguration.ColorMode.linear)
                        }
                        Toggle("16-bit float intermediates", isOn: $model.configuration.highPrecision)
                    }
                    Button("Refresh capabilities") {
                        Task { await model.refreshCapabilities() }
                    }
                    if model.target == .all {
                        Text("Scale choices use one received track. Other input sizes may pass through.")
                            .font(.caption)
                    }
                    Button("Apply") { Task { await model.apply() } }
                        .disabled(model.configuration.backend != .off && !model.scales.contains(model.configuration.scale))
                    Button(model.target == .all ? "Reset default to Off" : "Use call default") {
                        Task { await model.reset() }
                    }
                    if let error = model.error {
                        Text(error).foregroundColor(.red)
                    }
                }
                Section(header: Text("Effective status")) {
                    if visibleStatuses.isEmpty {
                        Text("Waiting for received video.")
                    }
                    ForEach(visibleStatuses, id: \.self) { track in
                        if let status = state.videoUpscalingStatuses[track] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(participantName(track)) · \(track.source == .camera ? "Camera" : "Screen share")")
                                Text("\(title(for: status.effectiveBackend)) · \(status.state.rawValue)")
                                Text("\(status.inputWidth)×\(status.inputHeight) → \(status.outputWidth)×\(status.outputHeight)")
                                Text(
                                    "\(status.processingMilliseconds, specifier: "%.1f") ms · \(status.enhancedFrames) enhanced · \(status.bypassedFrames) bypassed"
                                )
                                .font(.caption)
                                if let reason = status.fallbackReason { Text(reason).font(.caption) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Video upscaling")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .onAppear { Task { await model.select(model.target) } }
        .onChange(of: model.target) { target in Task { await model.select(target) } }
    }

    private var visibleStatuses: [VideoUpscalingTrack] {
        state.videoUpscalingStatuses.keys.filter {
            model.target == .all || model.target == .track($0)
        }.sorted {
            ($0.participantSessionID, $0.source.rawValue) < ($1.participantSessionID, $1.source.rawValue)
        }
    }

    private func participantName(_ track: VideoUpscalingTrack) -> String {
        state.remoteParticipants.first { $0.sessionId == track.participantSessionID }?.name ?? "Participant"
    }

    private func title(for backend: VideoUpscalingConfiguration.Backend) -> String {
        switch backend {
        case .off: return "Off"
        case .metalFX: return "MetalFX Spatial"
        case .videoToolbox: return "VideoToolbox Low Latency"
        }
    }
}
