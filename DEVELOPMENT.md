# Contributing & Development Guide — NativAI

Welcome to the **NativAI** project! This guide walks through the repository structure, local development workflows, testing procedures, and release packaging.

---

## 📁 Repository Structure Overview

```
.
├── Sources/
│   └── NativAI/
│       ├── Models/         # Core domain data models (DeviceSpecs, ModelEntry, ChatSession, etc.)
│       ├── Services/       # Ollama integration, RAG, Semantic Router, Memory, Dictation
│       ├── Views/          # SwiftUI UI (Chat, Catalog Browse, Installed, QuickAsk, Settings)
│       ├── Resources/      # Bundled resources (catalog.json base model catalog)
│       ├── AppState.swift  # Reactive central state container
│       ├── RootView.swift  # App entry view switcher
│       └── NativAIApp.swift# App lifecycle & menu commands
│
├── Tests/
│   └── NativAICoreTests/   # 110-test automated verification test suite
│
├── ARCHITECTURE.md         # Detailed macOS system architecture and data flow documentation
├── DEVELOPMENT.md          # Development, workflow, and testing guide (this file)
├── README.md               # Product overview and user installation guide
├── LICENSE                 # GNU General Public License v3 (GPLv3)
├── Package.swift           # Swift Package Manager manifest
├── test.sh                 # Fast test runner script (executes all 110 unit tests)
├── build_pkg.sh            # Universal macOS installer packager (.pkg)
└── uninstall.sh            # Complete uninstaller script (removes app, preferences, & models)
```

---

## 🛠 Local Setup & Requirements

- **Operating System**: macOS 14.0 Sonoma or later.
- **Xcode / Command Line Tools**: Xcode 15 or 16 installed in `/Applications/Xcode.app`.
- **Backend**: Ollama (installed locally at `/usr/local/bin/ollama` or via the app's onboarding flow).

---

## 🧪 Running the Test Suite

We maintain a comprehensive offline test suite covering:
- Fast-path deterministic semantic routing and edge-case boundary checks.
- Hardware adaptive model compatibility and stickiness scoring.
- In-memory vector embedding retrieval and Accelerate `vDSP` dot products.
- Multi-page CoreText paginated PDF transcript export.
- Conversation digest token pruning and long-term memory fact extraction.

To run all **110 unit tests**:

```bash
./test.sh
```

---

## 📦 Building the Universal macOS Installer

To generate a standalone, universal installer package (`arm64` + `x86_64`) ready for distribution:

```bash
bash build_pkg.sh
```

This script:
1. Compiles universal production binaries using SwiftPM.
2. Embeds bundled resources (`catalog.json`, `uninstall.sh`, `AppIcon.icns`).
3. Synthesizes a signed-ready installer component into `NativAI-1.0.0.pkg`.

---

## 🧩 Adding a Model to the Curated Catalog

To add a new verified model to the default catalog:
1. Open [`Sources/NativAI/Resources/catalog.json`](Sources/NativAI/Resources/catalog.json).
2. Append a new model definition under the `models` array specifying:
   - `name`: Exact Ollama model tag (e.g. `"llama3.2:3b"`).
   - `display_name`: Human-readable title.
   - `category`: `["general"]`, `["coder"]`, `["vision"]`, etc.
   - `role`: `"chat"`, `"coder"`, or `"vision"`.
   - `size_gb`: Disk size in gigabytes.
   - `min_ram_gb`: Minimum recommended unified memory.
   - `supports_vision`: `true` if multimodal, `false` otherwise.
3. Run `./test.sh` to ensure compatibility scoring and catalog decoding pass.
