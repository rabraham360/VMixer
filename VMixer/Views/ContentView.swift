//
//  ContentView.swift
//  VMixer
//
//  Created by Rohan Abraham on 5/2/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var engine = AudioEngine()
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showDebugStatus") private var showDebugStatus = false
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            HStack {
                Text("VMixer")
                    .font(.headline)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button(action: {
                    NSApp.activate(ignoringOtherApps: true)
                    if #available(macOS 14.0, *) {
                        openSettings()
                    } else {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)

                Spacer().frame(width: 12)
                
                Picker("", selection: $engine.selectedOutputDeviceID) {
                    ForEach(engine.outputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 130)


                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .focusable(false)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()

            // MARK: - Master Volume (Controls System Output)
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: {
                        engine.isMasterMuted.toggle()
                    }) {
                        Image(systemName: engine.isMasterMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                            .foregroundColor(engine.isMasterMuted ? .red : .primary)
                            .frame(width: 20)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)

                    Slider(value: $engine.masterVolume, in: 0...1)
                        .tint(engine.isMasterMuted ? .gray : .primary)

                    Text("\(Int(engine.masterVolume * 100))%")
                        .monospacedDigit()
                        .font(.caption)
                        .frame(width: 35, alignment: .trailing)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))

            Divider()

            // MARK: - Active Apps List
            if engine.targets.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "speaker.zzz")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("No apps detected.")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(engine.targets) { target in
                            TargetRowView(engine: engine, target: target)
                        }
                        
                        if showDebugStatus{
                            Divider()
                            Text(engine.statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity,alignment: .leading)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 340, height: 600)
    }
}
