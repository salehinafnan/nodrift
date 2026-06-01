<div align="center">
  <h1>Work Hour Tracker</h1>
  <p><b>A precision-engineered, local-first time tracking engine for high-performance professionals.</b></p>
  
  ![Environment](https://img.shields.io/badge/Environment-Browser_Native-000000?style=for-the-badge&logo=googlechrome)
  ![Storage](https://img.shields.io/badge/Storage-IndexedDB_LocalFirst-000000?style=for-the-badge&logo=databricks)
  ![License](https://img.shields.io/badge/License-MIT-000000?style=for-the-badge)
</div>

<br/>

The **Work Hour Tracker** is not just another time-logging app. It is a premium, client-side web application built for speed, privacy, and absolute accuracy. Running entirely within your browser, it features a zero-latency interface, advancedDOM virtualization for infinite scrolling, and uncompromising data privacy. 

No backend servers. No data harvesting. Your data belongs entirely to you.

---

## 💎 Premium Features

### 1. Zero-Latency Local-First Architecture
The tracker operates 100% locally using IndexedDB and LocalStorage. This means instantaneous interactions, zero loading spinners, and complete immunity to server outages. It is fully decoupled from the cloud.

### 2. High-Performance Virtual Logbook
Forget lagging browsers when you have thousands of entries. The custom-built **DOM Virtualization** engine only renders the rows currently visible in your viewport. Scroll through years of shift history flawlessly. Includes advanced multi-criteria filtering by date range, note tags, goal status, and timezone.

### 3. The 40-Hour Analytics Engine
A dynamic pace engine tracks your weekly progress (Monday–Friday) against a 40-hour goal. 
- **Pace Indicator**: Dynamically calculates the exact hours you need to work per day to hit your weekly target.
- **Cumulative Segments**: Visualizes your daily progression through a beautifully animated segmented progress bar.
- **Synthesized Success**: Utilizing the native Web Audio API, the app synthesizes a crisp 880Hz audio tone the moment you cross your 40-hour milestone.

### 4. Frictionless, Intelligent Inputs
The UI is built for speed-typists. It anticipates your intent so you spend less time logging and more time working:
- **Smart Time Normalizer**: Type `8` to get `08:00`. Type `1245` to get `12:45`. No colons needed.
- **Relative Date Parser**: Type `t` for today, `y` for yesterday, or `-5` to log a shift from 5 days ago. 

### 5. Uncompromising Safeguards
Your database remains uncorrupted through built-in automation:
- **Idle Lockout**: Auto-detects physical inactivity. If you step away, it pauses active timing and displays the exact duration you were away to ensure your logs are perfect.
- **Multi-Tab Sync Lockout**: Prevents database race conditions by locking out conflicting sessions if opened in multiple tabs.
- **Overnight Shift Mapping**: Shifts spanning past midnight (e.g., 11:00 PM to 4:00 AM) are intelligently preserved in the starting day’s record, preventing fragmented logs.

### 6. Artisan-Grade Theming
Choose between meticulously crafted aesthetics, powered by a dynamic UI that leverages modern CSS features like glassmorphism and vibrant gradients:
- **Midnight (Premium Noir)**: Deep blacks with high-contrast accents, optimized for dark environments to eliminate eye strain.
- **Glass (Frosted Glassmorphic)**: Translucent panes overlaid on ambient, animated gradient backdrops.

---

## ⚡ Keyboard Command Center

The app is built to be driven entirely by keyboard shortcuts for maximum efficiency:

| Hotkey | Action | Detail |
| :--- | :--- | :--- |
| `Spacebar` | **Toggle Timer** | Instantly switches between Active Work and Rest Break modes. |
| `S` | **Log Shift** | Opens the shift submission modal to archive your session. |
| `Escape` | **Clear / Close** | Clears row selections or exits any open modal window. |
| `ArrowUp` / `Down`| **Navigate** | Scrolls through your virtual logbook, highlighting rows. |
| `Enter` | **Open Details** | Expands the selected logbook entry to read full notes. |

---

## 🛠 Usage & Portability

### Getting Started
Because it is a native client-side application, there are no dependencies to install. 
1. Download the repository.
2. Double click `index.html` to open it in your browser.
3. Start tracking.

### Data Portability
You are never locked in. Export your entire operational state (settings, goals, active timers, and history) as a raw `.json` backup file, or export a perfectly formatted `.csv` spreadsheet for external reporting.

### Self-Contained Build System
For developers: The application uses a custom automated build process (`sync.bat` & `sync_utils.ps1`) to inline the pure logic from `utils.js` directly into `index.html`. This ensures the app remains 100% self-contained and perfectly portable as a single file.

---

<div align="center">
  <p><i>Engineered for Focus. Built for Performance.</i></p>
  <p>Licensed under the <a href="LICENSE">MIT License</a>.</p>
</div>
