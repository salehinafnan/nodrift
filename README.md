<div align="center">
  <img src="https://via.placeholder.com/150?text=NoDrift" alt="NoDrift Logo" width="120" />
  <h1>NoDrift</h1>
  <p><strong>Zero backend. Zero latency. Total privacy. One file.</strong></p>

  <p>
    <a href="https://github.com/nodrift/nodrift/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License" /></a>
    <img src="https://img.shields.io/badge/Lines-14%2C152-blueviolet?style=for-the-badge" alt="Lines" />
    <img src="https://img.shields.io/badge/Size-526KB-orange?style=for-the-badge" alt="Size" />
    <img src="https://img.shields.io/badge/Dependencies-0-brightgreen?style=for-the-badge" alt="Dependencies" />
  </p>
</div>

---

## 📖 Overview

Most time trackers are bloated SaaS tools that harvest data or barebones stopwatches that break when you close the tab. **NoDrift** is an enterprise-grade, single-file web application that runs entirely in your browser. 

It tracks active work hours, rest breaks, daily goals, and weekly workloads with analytical precision. Everything is stored locally on your machine via a failsafe IndexedDB + LocalStorage matrix. **No accounts. No servers. No subscriptions.**

---

## ✨ Features

- **Standalone Monolith**: 100% self-contained in a single `index.html` file. Zero external dependencies.
- **Drift-Resistant Timers**: Dual-clock system (`Date.now()` + `performance.now()`) with Web Worker background processing.
- **Intelligent Idle Management**: Monitors inactivity to automatically pause timers and prompt for time recovery.
- **Virtual Logbook**: Custom DOM virtualization capable of rendering thousands of records at 60fps.
- **Command Palette (HUD)**: Raycast-inspired keyboard-first interface for tracking, searching, and configuring.
- **Data Portability**: Seamless CSV export, JSON backup/restore, and auto-email drafting.

---

## 🏗️ Architecture & Workflow

NoDrift operates on a sophisticated client-side architecture featuring background threads, debounced state persistence, and emergency fallback systems.

```mermaid
flowchart TD
    classDef init fill:#312e81,stroke:#6366f1,stroke-width:2px,color:#fff
    classDef worker fill:#064e3b,stroke:#10b981,stroke-width:2px,color:#fff
    classDef logic fill:#701a75,stroke:#d946ef,stroke-width:2px,color:#fff
    classDef store fill:#7f1d1d,stroke:#ef4444,stroke-width:2px,color:#fff
    classDef ui fill:#1e3a8a,stroke:#3b82f6,stroke-width:2px,color:#fff
    classDef action fill:#0f172a,stroke:#94a3b8,stroke-width:2px,stroke-dasharray: 5 5,color:#fff

    subgraph Phase1 [1. Initialization & Bootstrap]
        direction TB
        Boot([App Launch: initApp]) ::: init
        LoadDB[(Load Logs from IndexedDB)] ::: store
        CheckHealth{DB Healthy?} ::: logic
        MergeEmerg[(Merge Emergency Backup)] ::: store
        HydrateLS[(Hydrate Session State<br/>LocalStorage)] ::: store
        StartWorker[[Start Web Worker Thread]] ::: worker
        
        Boot --> LoadDB
        LoadDB --> CheckHealth
        CheckHealth -- Yes --> MergeEmerg
        CheckHealth -- No --> DisableWrites[Disable Writes: RAM Only] ::: store
        MergeEmerg --> HydrateLS
        DisableWrites --> HydrateLS
        HydrateLS --> StartWorker
    end

    subgraph Phase2 [2. Core Timer & Event Loop]
        direction TB
        Tick((Worker Tick<br/>1000ms)) ::: worker
        Delta[Calculate Time Delta<br/>performance.now] ::: logic
        CheckMode{state.currentMode?} ::: logic
        UpdateWork[state.workAccumulated += delta] ::: logic
        UpdateBreak[state.breakAccumulated += delta] ::: logic
        SaveLS[(saveState<br/>Debounced 150ms)] ::: store
        
        Tick --> Delta
        Delta --> CheckMode
        CheckMode -- 'work' --> UpdateWork
        CheckMode -- 'break' --> UpdateBreak
        CheckMode -- 'null' --> Wait[Standby] ::: logic
        UpdateWork --> SaveLS
        UpdateBreak --> SaveLS
    end

    subgraph Phase3 [3. Intelligent Idle Management]
        direction TB
        Activity((Mouse/Key Events)) ::: ui
        SetLastAct[Update lastActivity timestamp] ::: logic
        Heartbeat{Date.now - lastActivity<br/>> idleThreshold?} ::: logic
        Lock[Trigger Idle Lock<br/>Pause Timers] ::: logic
        Modal((Show Idle Modal)) ::: ui
        UserResolve{User Resolution} ::: ui
        Keep[Keep Idle Time] ::: action
        Discard[Discard Idle Gap] ::: action
        
        Activity --> SetLastAct
        SetLastAct --> Heartbeat
        Tick -.-> Heartbeat
        Heartbeat -- Yes --> Lock
        Lock --> Modal
        Modal --> UserResolve
        UserResolve -- Click Keep --> Keep
        UserResolve -- Click Discard --> Discard
        Keep --> Resume[Resume Timers] ::: logic
        Discard --> SubTime[Subtract Gap from state] ::: logic
        SubTime --> Resume
    end

    subgraph Phase4 [4. Submission & Export Workflow]
        direction TB
        ClickSubmit((User Clicks Submit)) ::: ui
        Build[Build Log Object] ::: logic
        WriteDB[(saveLogsToDB<br/>IndexedDB)] ::: store
        WriteEmerg[(Update Emergency Backup<br/>LocalStorage)] ::: store
        CheckHooks{Check Setting Hooks} ::: logic
        AutoBackup[Generate JSON Auto-Backup] ::: action
        AutoEmail[Draft Summary Email] ::: action
        Reset[Reset Session State<br/>Clear variables] ::: logic
        
        ClickSubmit --> Build
        Build --> WriteDB
        Build --> WriteEmerg
        WriteDB --> CheckHooks
        CheckHooks -- autoBackup enabled --> AutoBackup
        CheckHooks -- autoEmail enabled --> AutoEmail
        AutoBackup --> Reset
        AutoEmail --> Reset
        CheckHooks -- none --> Reset
    end

    %% Global Inter-Phase Connectors
    StartWorker ===> Tick
    SaveLS -.-> ClickSubmit
    Resume -.-> Tick
    Reset -.-> Wait
```

---

## 🚀 Getting Started

No build steps. No `npm install`.

1. **Download** or clone this repository.
2. **Open `index.html`** in any modern web browser (Chrome, Firefox, Safari, Edge).
3. Press `Spacebar` to start tracking.

> **Self-Hosting**: Deploy the folder directly to Vercel, Netlify, or GitHub Pages. Note that browser storage is origin-bound; use the **Export/Import JSON** feature when migrating domains.

---

## 🛠️ Core Capabilities

### Command Palette (HUD)
Press `/` to open the full-featured, fuzzy-search command center. Type natural language to control the app:
- `start work` / `stop break`
- `goal 8h 30m`
- `theme onyx`
- `export week`
- **NLP Writing**: `add yesterday 9am to 5pm worked on dashboard redesign`

### Failsafe Safety & Integrity
- **Multi-Tab Sync Lockout**: `BroadcastChannel` + localStorage leasing ensures only one master tab writes to the DB.
- **Emergency Recovery**: Submits are synchronously backed up to `localStorage` to catch logs missed by IndexedDB during dirty browser exits.
- **RAM-Only Fallback**: Gracefully degrades to a RAM-only mode if the user's storage quota is exceeded.

### Virtual Logbook & Heatmaps
The built-in analytics engine includes:
- **O(1) Virtualized Logbook**: Search, filter, and edit thousands of logs instantly.
- **GitHub-Style Heatmap**: Visualizes your daily effort intensity.
- **40-Hour Pacing**: Dynamically calculates your required daily velocity to hit your weekly target.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| <kbd>Spacebar</kbd> | Toggle Work / Break timers |
| <kbd>S</kbd> | Submit current shift |
| <kbd>/</kbd> | Open Command Palette |
| <kbd>Ctrl</kbd> + <kbd>S</kbd> | Auto-Backup & Draft Summary |
| <kbd>Alt</kbd> + <kbd>T</kbd> | Cycle Themes (SF Dark, Onyx, Cobalt, SF Light) |
| <kbd>Alt</kbd> + <kbd>1</kbd> / <kbd>2</kbd> | Switch between Insights / Logbook |
| <kbd>E</kbd> / <kbd>D</kbd> / <kbd>C</kbd> | Edit, Delete, Copy selected log |

---

## 💻 Development & Build System

While shipped as a monolith, the source code is built modularly.
- **`utils.js`**: Pure functions (`formatDuration`, `fuzzyScore`, etc.) separated for testability.
- **`index.test.html`**: Test harness.
- **`sync.bat` / `sync_utils.ps1`**: Automated build scripts that inline `utils.js` back into `index.html`.

---

## 📄 License

This project is open-source and licensed under the [MIT License](LICENSE).
