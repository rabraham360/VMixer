//
//  VMixerApp.swift
//  VMixer
//
//  Created by Rohan Abraham on 5/2/26.
//

import SwiftUI

@main
struct VMixerApp: App {
    var body: some Scene {
        
        // This creates the icon in the top right of your Mac screen
        MenuBarExtra("VMixer", systemImage: "slider.horizontal.3") {
            ContentView()
        }
        // Tells macOS to treat this like a detached popover window
        .menuBarExtraStyle(.window)
        
        // Standard settings window accessible via the gear icon
        Settings {
            SettingsView()
        }
    }
}
