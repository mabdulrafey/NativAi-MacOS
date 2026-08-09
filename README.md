# NativAI - Standalone Local LLM Manager for macOS

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014.0%2B-apple.svg)](https://developer.apple.com/macos/)
[![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon%20%7C%20Intel-orange.svg)]()
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-red.svg)](https://swift.org)
[![Download Release](https://img.shields.io/badge/Download-v1.0.0%20.pkg-brightgreen.svg?style=for-the-badge&logo=apple)](https://github.com/mabdulrafey/NativAi-MacOS/releases/download/v1.0.0/NativAI-1.0.0.pkg)

**NativAI** is a high-performance, standalone desktop application engineered specifically for macOS. Designed with a privacy-first architecture, NativAI manages, routes, and executes open-source Large Language Models (LLMs), Vision models, and Embedding models locally on your Mac—with zero cloud telemetry or external API dependencies.

---

## ⬇️ Quick Download & Installation

[<img src="https://img.shields.io/badge/Download%20NativAI%20v1.0.0%20Installer%20(.pkg)-000000?style=for-the-badge&logo=apple&logoColor=white" width="340" />](https://github.com/mabdulrafey/NativAi-MacOS/releases/download/v1.0.0/NativAI-1.0.0.pkg)

- 📦 **[Direct Download: NativAI-1.0.0.pkg](https://github.com/mabdulrafey/NativAi-MacOS/releases/download/v1.0.0/NativAI-1.0.0.pkg)** *(1.9 MB Universal macOS Installer)*
- 🏷️ **[View Latest GitHub Release Notes](https://github.com/mabdulrafey/NativAi-MacOS/releases/tag/v1.0.0)**

---

## 🌟 Executive Summary

NativAI turns your Mac into a self-contained AI workstation. By leveraging native Apple Silicon Metal acceleration via Ollama, NativAI delivers responsive multi-model intelligence across text chat, code generation, document Q&A, vision analysis, image synthesis, and local voice dictation.

Built with a hardware-adaptive execution engine, NativAI dynamically scales memory limits and context windows to ensure smooth performance—even on entry-level Macs with 8GB of unified memory.

---

## 🔥 Key Features

### 1. 🧠 Autonomous Multi-Model Routing ("Auto Mode")
- **Intent-Driven Dispatch**: Automatically routes incoming prompts to the optimal installed model (Chat, Coder, Vision, or Image Generation) based on real-time task classification.
- **Tag-Agnostic Model Resolution**: Seamlessly resolves model tags and variants without breaking catalog metadata.

### 2. 🛡️ Hardware-Adaptive Memory Management (RAM Optimization)
- **Automatic Model Eviction**: Sends immediate `keep_alive: 0` eviction signals when switching models on 8GB machines to prevent NVMe disk swapping.
- **Dynamic Context Windowing**: Scales context windows adaptively (e.g. capping at 4,096 tokens on 8GB Macs) to eliminate memory thrashing.
- **Circuit Breaker & Stop Button**: Real-time generation cancel button paired with a 4,096-token guardrail to prevent infinite generation loops.

### 3. 📚 Offline Document RAG & Folder Search
- **Local Vector Embeddings**: Uses `nomic-embed-text` to generate 768-dimensional vector embeddings entirely on-device.
- **Cosine Similarity Retrieval**: Automatically chunks long documents (>4,000 chars) into 300-word segments and injects top-matching excerpts into model context.

### 4. 👁️ Session Artifact Ledger & Image Comparison
- **Multi-Artifact Tracking**: Chronologically indexes generated and uploaded visual assets during a conversation session.
- **Comparative Ordinal Resolution**: Resolves queries like *"compare image 1 with image 2"* into target visual payloads for vision models.

### 5. 🎙️ On-Device Dictation & Personalization Memory
- **Private Voice Dictation**: Leverages macOS `SFSpeechRecognizer` with forced on-device speech-to-text processing.
- **Long-Term Memory Ledger**: Automatically extracts and stores key user preferences and facts across sessions.

---

## 🛠 Tech Stack Breakdown

- **User Interface**: Native SwiftUI & AppKit integration for liquid dark/light mode transitions and macOS material rendering.
- **Core Engine**: Ollama REST API integration over local Unix sockets/HTTP.
- **Embeddings & Vector Math**: Accelerate framework cosine similarity calculations.
- **Speech & Audio**: Apple `AVFoundation` and `Speech` framework (`requiresOnDeviceRecognition = true`).
- **Build System**: Swift Package Manager (SPM) with universal binary packaging (`x86_64` and `arm64`).

---

## 💻 System Requirements

- **Operating System**: macOS 14.0 (Sonoma) or newer.
- **Processor**: Apple Silicon (M1/M2/M3/M4) recommended; Intel Macs supported.
- **RAM**: 8 GB minimum (16 GB+ recommended for simultaneous 7B+ models).
- **Backend Dependency**: Local Ollama server (automatically installed during onboarding if missing).

---

## 🚀 Build & Installation Guide

### Option A: Build Universal Installer Package (`.pkg`)
Run the automated build script in the repository root:

```bash
bash build_pkg.sh
```

This will compile universal binaries for `arm64` and `x86_64`, assemble the `.app` bundle, and generate `NativAI-1.0.0.pkg`.

### Option B: Build via Swift Package Manager
```bash
swift build -c release
```

To run unit tests:
```bash
swift test
```

---

## 📜 License & Copyright

**Copyright (C) 2026 Muhammad Abdul Rafey**

NativAI is free software released under the **GNU General Public License v3.0 (GPLv3)**. You are free to redistribute, modify, and run this software under the terms of the GPLv3 license. See the [LICENSE](LICENSE) file for full details.

- **Author & Lead Architect**: Muhammad Abdul Rafey
- **Repository**: [https://github.com/mabdulrafey/NativAi-MacOS](https://github.com/mabdulrafey/NativAi-MacOS)
