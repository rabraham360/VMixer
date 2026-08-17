//
//  TargetRowView.swift
//  VMixer
//
//  Created by Rohan Abraham on 5/2/26.
//

import SwiftUI

struct TargetRowView: View {
    @ObservedObject var engine: AudioEngine
    let target: AudioEngine.Target
    @State private var preMuteVolume: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            
            // MARK: - App Header
            HStack {
                if let icon = target.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .foregroundColor(.secondary)
                }
                
                Text(target.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                Spacer()
                
                Button(action: { engine.removeTarget(pid: target.pid) }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }

            // MARK: - Controls Row
            HStack(spacing: 12) {
                VUMeterView(level: target.level)
                    .frame(height: 20)
                
                Button(action: {
                    engine.setMuted(pid: target.pid, muted: !target.isMuted)
                }) {
                    Image(systemName: target.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(target.isMuted ? .red : .primary)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .focusable(false)

                Slider(
                    value: Binding(
                        get: { Double(target.volume) },
                        set: { newValue in
                            engine.setVolume(pid: target.pid, volume: Float(newValue))
                            if newValue <= 0.001 && !target.isMuted {
                                engine.setMuted(pid: target.pid, muted: true)
                            } else if newValue > 0.001 && target.isMuted {
                                engine.setMuted(pid: target.pid, muted: false)
                            }
                        }
                    ),
                    in: 0...1
                )
                .tint(target.isMuted ? .gray : .blue)
                
                Text("\(Int(target.volume * 100))%")
                    .monospacedDigit()
                    .font(.caption)
                    .frame(width: 35, alignment: .trailing)
            }
            .frame(height: 24)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}
