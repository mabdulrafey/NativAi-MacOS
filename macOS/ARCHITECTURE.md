# NativAI — macOS Architecture (Phase 1)

## Xcode Project Setup

**Target:** macOS 14.0+ · SwiftUI App lifecycle · Universal (arm64 + x86_64)
**Bundle ID:** `com.nativai.app`

### Required Build Settings
| Setting | Value | Reason |
|---|---|---|
| `ARCHS` | `arm64 x86_64` | Universal binary |
| Hardened Runtime | ON | Notarization |
| `com.apple.security.app-sandbox` | **OFF** | Sandbox forbids spawning `ollama` + binding localhost:11434 |
| `com.apple.security.network.client` | ON | REST calls to Ollama |
| Frameworks | `Metal`, `IOKit` | Device + hardware inspection |

### Directory Layout

```
NativAI/
├─ NativAI.xcodeproj
├─ NativAI/
│  ├─ NativAIApp.swift              // @main, injects AppState, starts Ollama
│  ├─ AppState.swift                // ObservableObject root store
│  │
│  ├─ Core/
│  │  ├─ HardwareScanner.swift      // ✅ Phase 1
│  │  ├─ OllamaManager.swift        // ✅ Phase 1
│  │  ├─ RecommendationEngine.swift // ✅ Phase 1
│  │  └─ Models.swift               // ✅ Phase 1 (shared types)
│  │
│  ├─ Networking/                   // Phase 2
│  │  ├─ OllamaAPIClient.swift      // /api/pull + /api/generate streaming
│  │  └─ StreamDecoder.swift        // NDJSON line splitter
│  │
│  ├─ Views/                        // Phase 2
│  │  ├─ Onboarding/
│  │  ├─ Downloader/
│  │  └─ Chat/
│  │
│  └─ Resources/
│     ├─ Assets.xcassets
│     └─ ollama                     // ⬅ bundled universal binary (chmod +x)
└─ Scripts/
   └─ fetch_ollama.sh               // build-phase: download + lipo universal binary
```

### Bundling the Ollama Binary
1. Add `Resources/ollama` to the target's **Copy Bundle Resources** phase.
2. Add a **Run Script** phase *after* copy:
   `chmod +x "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ollama"`
3. Sign it as a nested executable — it must be signed with the same Team ID
   and inherit entitlements, otherwise Gatekeeper kills the child process.

Result: `NativAI.app/Contents/Resources/ollama` — no Homebrew, no terminal,
no user install step. Models land in `~/.ollama/models` (writable, persists
across app updates).

### Data Flow (Phase 1 scope)

```
NativAIApp.launch
      │
      ├─▶ HardwareScanner.scan()  ──▶ SystemProfile { ram, vram, tier, isAppleSilicon }
      │
      ├─▶ OllamaManager.start()   ──▶ spawn Resources/ollama serve (detached, no TTY)
      │                                └─ poll GET /  until "Ollama is running"
      │
      └─▶ RecommendationEngine.recommend(tier:intent:) ──▶ [ModelRecommendation]
```

### Design Notes
- **Unified memory:** on Apple Silicon `MTLDevice.recommendedMaxWorkingSetSize`
  is the honest GPU-usable ceiling (~75% of physical RAM). Tiering on this
  rather than raw RAM avoids recommending a 70B model to a 24GB M4 that can
  only hand ~18GB to the GPU.
- **No terminal windows:** `Process` with `stdout/stderr` redirected to `Pipe`
  and no `NSWorkspace.open` means zero UI artifacts. `ollama serve` is a plain
  daemon — it never wants a TTY.
- **Idempotent start:** if port 11434 already answers (user has Ollama installed
  via the official app), we attach to it instead of spawning a second copy.
