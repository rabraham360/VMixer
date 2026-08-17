//
//  SettingsView.swift
//  VMixer
//
//  Created by Rohan Abraham on 5/2/26.
//

import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            
            IgnoreListSettingsView()
                .tabItem {
                    Label("Ignored Apps", systemImage: "nosign")
                }
        }
        .frame(width: 450, height: 300)
    }
}

// MARK: - General Settings Tab
struct GeneralSettingsView: View {
    @AppStorage("autoHookEnabled") private var autoHookEnabled = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showDebugStatus") private var showDebugStatus = false
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable Auto-Hooking", isOn: $autoHookEnabled)
                Text("Automatically add apps to VMixer when they play audio or become the active window.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom)

            Section {
                Toggle("Launch VMixer at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {oldValue, newValue in
                        toggleLaunchAtLogin(enabled: newValue)
                    }
                Text("Start the audio mixer automatically when you turn on your Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section {
                Toggle("Show Debug Status Bar", isOn: $showDebugStatus)
                Text("Display the background audio engine status at the bottom of the main window.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(30)
    }
    
    private func toggleLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to toggle Launch at Login: \(error.localizedDescription)")
        }
    }
}

// MARK: - Ignored Apps Tab
struct IgnoreListSettingsView: View {
    @AppStorage("ignoredBundleIDs") private var ignoredBundleIDs = "com.apple.finder,com.apple.systempreferences,com.apple.ActivityMonitor,com.apple.dt.Xcode,com.apple.Terminal"
    
    @State private var selectedBundleID = ""
    @State private var runningApps: [(name: String, bundleID: String)] = []

    var ignoredArray: [String] {
        ignoredBundleIDs.split(separator: ",").map(String.init)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("VMixer will never auto-hook apps with these Bundle IDs.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            List {
                ForEach(ignoredArray, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                        Spacer()
                        Button(action: {
                            remove(bundleID: bundleID)
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .border(Color(NSColor.separatorColor))
            
            HStack {
                Picker("Running Apps:", selection: $selectedBundleID) {
                    Text("Select an app to ignore...").tag("")
                    ForEach(runningApps, id: \.bundleID) { app in
                        Text("\(app.name) (\(app.bundleID))").tag(app.bundleID)
                    }
                }
                .labelsHidden()
                
                Button(action: {
                    refreshRunningApps()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh running apps list")

                Button("Add") {
                    add(bundleID: selectedBundleID)
                    selectedBundleID = ""
                }
                .disabled(selectedBundleID.isEmpty)
            }
        }
        .padding()
        .onAppear {
            refreshRunningApps()
        }
    }
    
    private func refreshRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier > 0 }
            .compactMap { app -> (name: String, bundleID: String)? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                let name = app.localizedName ?? bundleID
                return (name, bundleID)
            }
            .reduce(into: [String: String]()) { dict, app in
                dict[app.bundleID] = app.name
            }
            .map { (name: $0.value, bundleID: $0.key) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        self.runningApps = apps
    }
    
    private func add(bundleID: String) {
        let clean = bundleID.trimmingCharacters(in: .whitespaces)
        var current = ignoredArray
        if !current.contains(clean) && !clean.isEmpty {
            current.append(clean)
            ignoredBundleIDs = current.joined(separator: ",")
        }
    }
    
    private func remove(bundleID: String) {
        var current = ignoredArray
        current.removeAll { $0 == bundleID }
        ignoredBundleIDs = current.joined(separator: ",")
    }
}
