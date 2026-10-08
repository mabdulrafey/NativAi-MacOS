# NativAI — macOS System Architecture

## 1. System Overview

**NativAI** is a high-performance, privacy-first desktop application engineered specifically for macOS (macOS 14.0 Sonoma and newer). It orchestrates, routes, and executes local Large Language Models (LLMs), Vision models, and Embedding models entirely on the user's Mac.

```mermaid
graph TD
    User([User Prompt / Media / PDF]) --> UI[SwiftUI & AppKit Presentation Layer]
    UI --> AppState[AppState & ChatViewModel]
    AppState --> Router[SemanticRouter & IntentClassifier]
    AppState --> RAG[DocumentRAGService & PDFKit]
    AppState --> Memory[MemoryStore & MemoryFact Ledger]
    AppState --> Scorer[ModelScorer & SpecScanner]
    Router --> OllamaMgr[OllamaManager - HTTP 127.0.0.1:11434]
    Scorer --> OllamaMgr
    RAG --> Accelerate[Accelerate vDSP Vector Math]
    Memory --> Accelerate
    OllamaMgr --> Engine[Ollama Engine Daemon]
```

### Privacy & Network Boundaries
NativAI enforces strict network isolation for core operations:
* **100% On-Device / Zero Network**: Text chat inference, document parsing/RAG, memory vector search, and voice dictation (`SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`) execute entirely on local hardware with zero cloud telemetry.
* **Controlled Network Egress**:
  * **Engine Installer**: Downloads the official Ollama macOS package from `ollama.com` if not already installed.
  * **Web Search**: Automatically triggered when a query contains temporal/factual keywords ("weather", "news", "today", "2026", "who won", "stock price", "latest", "ceo of") or explicit search requests, querying DuckDuckGo HTML / `wttr.in`.
  * **Image Generation**: Generates images via `image.pollinations.ai` (badged as "Pollinations AI" only upon successful online generation) with an offline vector canvas fallback (badged as "Offline Canvas") when disconnected or when remote requests fail.

---

## 2. Directory Layout & Module Structure

The project is structured as a Swift Package Manager (SPM) universal application target with dedicated domain layers:

```
Sources/NativAI/
├── Models/                             # Core Data Models
│   ├── DeviceSpecs.swift               # Hardware tier & dynamic context window calculation
│   ├── ModelEntry.swift                # Catalog model entry & compatibility representation
│   ├── ModelCapabilities.swift         # Probed model capabilities (vision, tools, thinking)
│   ├── DisplayMessage.swift            # Chat message entity & transcript serialization
│   ├── MessageAttachment.swift         # Typed attachments (images, text/code files)
│   ├── SessionArtifact.swift           # Multi-modal artifact ledger & ordinal references
│   ├── ChatSession.swift               # Session persistence & auto-title lifecycle
│   └── MemoryFact.swift                # Normalized cross-session preference/fact ledger
│
├── Services/                           # Core Engine Services
│   ├── OllamaManager.swift             # Process supervisor & REST API client (127.0.0.1:11434)
│   ├── SpecScanner.swift               # Hardware scanner using sysctl & system_profiler
│   ├── SemanticRouter.swift            # Fast-path pattern matching & intent classification
│   ├── ModelScorer.swift               # Capability matching with 1.8x model stickiness margin
│   ├── CapabilityProbe.swift           # Dynamic /api/show capability discovery
│   ├── DocumentRAGService.swift        # In-memory document chunking & retrieval
│   ├── PDFVisualExtractor.swift        # PDF visual card & page extraction
│   ├── EmbeddingService.swift          # Accelerate framework (vDSP) SIMD vector dot product
│   ├── MemoryStore.swift               # Persistent long-term memory store
│   ├── MemoryExtractor.swift           # Rule-based preference/fact extraction
│   ├── ConversationDigest.swift        # Token-aware monotonic compaction for long chats
│   ├── TokenBudget.swift               # Dynamic context window allocator
│   ├── IntentClassifier.swift          # Domain classifier (.general, .coding, .vision, .image)
│   ├── CatalogService.swift            # Model catalog loader & tier recommendation engine
│   ├── DynamicCatalogDiscoveryService.swift # Curated hardware-compatible model catalog activation
│   ├── DictationService.swift          # On-device Speech-to-Text via Speech framework
│   ├── WebSearchService.swift          # DuckDuckGo HTML scraper & weather lookups
│   ├── ImageGenerationService.swift    # Hybrid Pollinations AI & offline vector canvas art
│   ├── LocalCodeSandboxService.swift   # Sandboxed local code interpreter runner
│   ├── QuickAskManager.swift           # System-wide floating prompt supervisor
│   ├── PerformanceMonitor.swift        # Real-time token generation throughput tracker
│   ├── ContextualReferenceResolver.swift # Resolves natural language back-references
│   ├── ChatHistoryStore.swift          # JSON persistence for chat sessions
│   ├── ChatTitleGenerator.swift        # Lightweight prompt titling
│   ├── SessionExportService.swift      # Multi-page CoreText paginated PDF, Markdown & HTML export
│   └── FormattingHelpers.swift         # Byte and token formatting utilities
│
├── Views/                              # Native SwiftUI UI Layer
│   ├── MainShellView.swift             # Main application three-column layout shell
│   ├── Browse/                         # Model catalog, manual pull popover, compatibility badges
│   ├── Chat/                           # ChatView, ChatViewModel, Transcript, Composer, GapCard
│   ├── Installed/                      # Installed model management, delete actions, size tracking
│   ├── Onboarding/                     # Welcome flow, hardware tier profiling, model recommendations
│   ├── QuickAsk/                       # Floating global quick ask spotlight panel
│   ├── Settings/                       # Device specs, system status, storage breakdown, uninstaller
│   └── Storage/                        # Disk usage inspector and model cleanup tools
│
├── Resources/                          # Bundled Resources
│   └── catalog.json                    # Curated base model metadata catalog
│
├── Tests/NativAICoreTests/             # 110-Test Offline Verification Suite
│   ├── RoutingFastPathTests.swift      # Deterministic router & edge-case intent tests
│   ├── ModelScorerTests.swift          # Hardware compatibility & stickiness tests
│   ├── ChatSessionTests.swift          # Multi-page PDF export & session lifecycle tests
│   ├── DocumentRAGServiceTests.swift   # Vector similarity & text chunking tests
│   ├── SessionArtifactTests.swift      # Visual artifact ledger & ordinal references
│   ├── TokenBudgetTests.swift          # Context window allocation & trim tests
│   ├── MemoryTests.swift               # Long-term preference store & retrieval tests
│   └── ConversationDigestTests.swift   # Chat history compaction & token capping tests
│
├── build_pkg.sh                        # Universal installer builder (.pkg)
├── test.sh                             # Automated test suite runner (110 tests)
├── uninstall.sh                        # Complete uninstaller script
└── AppState.swift                      # Central reactive application state store
```

---

## 3. Core Architectural Subsystems

### 3.1 Hardware-Adaptive Profiling & Memory Safety
* **Hardware Inspection**: `SpecScanner` inspects `sysctlbyname("hw.memsize")` for physical memory, `sysctlbyname("hw.ncpu")` for core counts, and `sysctlbyname("hw.optional.arm64")` to detect Apple Silicon unified memory architecture. Human-readable chip and GPU names are retrieved via `system_profiler`.
* **Tier Categorization**:
  * **Essential** (`< 16 GB` RAM): Capped at 4K–8K context; 4B models fit comfortably, >4B models run slower, and 8B+ models are unsupported.
  * **Performance** (`16 to < 24 GB` RAM): Scaled up to 16,384 context; supports 7B–14B models.
  * **Workstation** (`≥ 24 GB` RAM): Unconstrained context; supports large 32B–70B models.
* **Dynamic Context Scaling**: `DeviceSpecs.effectiveContextLength` dynamically clamps context windows based on RAM and model size (e.g. 4,096 tokens for >2 GB models on ≤ 8.5 GB Macs, 8,192 for smaller models; up to 16,384 tokens on 16 GB machines).
* **OOM Prevention**: `ChatViewModel` proactively evicts resident models using `keep_alive: 0` when switching models on 8GB machines to prevent NVMe disk swapping.

### 3.2 Semantic Routing & Model Stickiness
* **Intent Classification**: Evaluates user prompts across regex fast-paths and semantic signals into `.general`, `.coding`, `.vision`, or `.image`.
* **Model Stickiness Margin**: To avoid costly multi-second model reload overhead and mid-conversation voice shifts, `ModelScorer` implements a **1.8× margin rule**: the current resident model (`currentSessionModel`) is retained unless an alternative model scores at least 1.8× higher (calibrated to require roughly a 4× size improvement). The margin relaxes to 1.05× when transitioning from a small vision model back to general text.

### 3.3 Hardware-Accelerated Vector Similarity (Accelerate Framework)
* **SIMD Dot Products**: `EmbeddingService` leverages Apple's `Accelerate` framework (`vDSP_dotprD`) to calculate cosine similarity between query embeddings and stored document/memory vectors without blocking the main UI thread.

### 3.4 Automated Web Search Grounding
* **Keyword-Driven Triggers**: `WebSearchService.requiresWebSearch` detects temporal/factual keywords ("weather", "news", "today", "2026", "who won", "stock price", "latest", "ceo of") and explicit search queries, pulling real-time snippets from DuckDuckGo HTML or `wttr.in` to ground model completions.

### 3.5 Session Artifact Ledger & Visual Follow-Ups
* **Artifact Tracking**: `SessionArtifact` maintains a chronological ledger of generated and uploaded visual assets.
* **Contextual Resolution**: When users submit follow-ups like *"what font is in the first image?"* or *"describe the logo"*, `SessionArtifact.resolveTarget` resolves the query to the exact visual payload using natural language ordinals ("first", "second") and content labels.

### 3.6 Real-Time Throughput Monitoring
* **Streaming Metrics**: `PerformanceMonitor` records tokens received over elapsed streaming intervals.
* **Header Telemetry**: The chat header dynamically displays live token throughput (e.g., `⚡ 32.4 t/s`) during generation.

---

## 4. Verification & Testing

The core architecture is verified via XCTest:
* **Test Suite**: `Tests/NativAICoreTests/`
* **Test Coverage**: 109 automated unit tests validating Token Budgeting, Conversation Compaction, Memory Fact Normalization, Hardware Adaptive Contexts, Model Scoring, and Routing Fast Paths.
* **Target Platforms**: Universal macOS binary (`arm64` and `x86_64`) targeting macOS 14.0+.
