//
//  VUMeterView.swift
//  VMixer
//
//  Created by Rohan Abraham on 5/2/26.
//

import SwiftUI

struct VUMeterView: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Background Track (Empty)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(NSColor.tertiaryLabelColor).opacity(0.2))
                
                // Lit Audio Track (Solid Gradient)
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [.green, .yellow, .red]),
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    // This mask slides up and down based on the audio level
                    .mask(
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .frame(height: geo.size.height * CGFloat(max(0, min(level, 1.0))))
                        }
                    )
            }
            .animation(.easeOut(duration: 0.1), value: level)
        }
        // Forces the bar to be sleek and tiny
        .frame(width: 6)
    }
}
