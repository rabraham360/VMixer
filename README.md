# VMixer 
> **A streamlined volume mixer and audio control interface.**

[![GitHub license](https://img.shields.io/github/license/rabraham360/vmixer)](/LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/rabraham360/vmixer)](https://github.com/rabraham360/vmixer/releases)

**VMixer** is a lightweight application designed to give users granular control over their system's audio streams. Built as a portfolio project, it focuses on clean UI/UX and efficient management of system audio APIs to allow per-application volume scaling.

---

## Features
- **Per-App Volume Control:** Adjust audio levels for individual applications without affecting the master volume.
- **Real-time Monitoring:** Visual feedback of active audio streams.
- **Minimalist Interface:** Designed to stay out of the way while providing maximum utility.
- **Lightweight & Fast:** Optimized for low CPU and RAM usage.

## Tech Stack
- **Language:** Swift 5+
- **Framework:** [SwiftUI or AppKit]
- **APIs:** Core Audio, Audio Toolbox
- **IDE:** Xcode

## Getting Started

### Prerequisites
- A Mac running **macOS [e.g., Ventura/Sonoma]** or later.
- **Xcode 15+** (if building from source).

## Installation
### Homebrew
```bash
brew tap rabraham360/vmixer
brew install --cask vmixer
```

## Challenges & Learnings
- The Challenge: Handling real-time audio stream updates without causing interface lag.
- The Solution: Implemented [e.g., threading/asynchronous loops] to ensure the UI remains responsive even when multiple audio sources are being polled simultaneously.

### License
This project is licensed under the MIT License - see the [LICENSE](/LICENSE) file for details.

Created by Rohan Abraham Check out my other projects on [GitHub](https://github.com/rabraham360)
