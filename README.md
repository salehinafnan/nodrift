# Work Hour Tracker

> A premium, high-performance, local-first client-side web application designed to track active work hours, rest breaks, and weekly workloads with analytical precision.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Environment](https://img.shields.io/badge/env-browser-success.svg)
![Storage](https://img.shields.io/badge/storage-localfirst-orange.svg)

The **Work Hour Tracker** is built entirely on client-side web technologies. It runs locally in your web browser and communicates with zero external backend servers. Your data belongs entirely to you and is stored safely using IndexedDB and LocalStorage.

---

## 🚀 Features

- **Local-First Architecture:** Complete privacy. No backend servers. Fast, reliable, and secure.
- **Advanced Time Tracking:** Separate timers for productive hours and rest breaks.
- **Dynamic Weekly Analytics:** Track your pace toward a 40-hour work week with intelligent insights.
- **High-Performance Virtual Logbook:** Handles extensive history smoothly by incorporating DOM virtualization.
- **Theme Engine:** Choose between *Midnight (Premium Noir)* and *Glass (Frosted Glassmorphic)* for optimal aesthetics.
- **Data Portability:** Export and import your entire database as JSON, or export standard CSV spreadsheets for external reporting.

---

## 🛠 Getting Started

### Prerequisites

Since this is a client-side application, all you need is a modern web browser (Chrome, Firefox, Edge, Safari).

### Usage

1. **Clone or Download** the repository to your local machine.
2. **Open `index.html`** in your preferred web browser.
3. Start tracking! 

*(Optional)* **Self-Hosting**: You can deploy this static folder to platforms like Vercel, Netlify, or GitHub Pages. Note that browser storage is tied to the domain name (origin). If migrating from a local file to a hosted URL, use the **Export/Import JSON** feature.

---

## 📖 User Guide

### Time-Tracking & Session Controls

The app uses two main counters: the **Work Timer** (active productive hours) and the **Break Timer** (rest or pause durations).

1. **Start Tracking**: Click the **Work** button (or press `Spacebar`) to initiate your shift.
2. **Taking Breaks**: Click the **Break** button (or press `Spacebar`) when pausing tasks. The work timer freezes, and the break timer activates.
3. **Submitting a Shift**: Click **Log Shift** (or press `S`). A modal allows you to add custom shift notes (e.g., tags, task descriptions) before finalizing.

### Keyboard Shortcuts

Maximize operational speed by utilizing global hotkeys (disabled when typing in input fields):

| Hotkey | Action |
| :--- | :--- |
| `Spacebar` | **Toggle Timer Mode** (Work / Break) |
| `S` | **Open Log Shift Modal** |
| `Escape` | **Clear Selection / Close Modals** |
| `ArrowUp` / `Down`| **Logbook Row Selection** |
| `Enter` | **Open Highlighted Note** |
| `Delete` | **Delete Highlighted Entry** |

### Safety & Synchronization Safeguards

- **Idle Lockout**: Auto-detects physical inactivity and pauses active timing to prevent false logs.
- **Window Leave Protection**: A warning popup prevents accidental page closure while a timer is active.
- **Overnight Shift Mapping**: Shifts spanning across midnight are preserved inside the starting day's record to prevent fragmented logs.
- **Multi-Tab Sync Lockout**: Prevents write race conditions if multiple tabs are opened simultaneously.

### Goals & Analytics

- **Daily Work Target**: Adjust your daily goal incrementally. Type shorthand like `830` to instantly set `8h 30m`.
- **Weekly 40-Hour Engine**: Tracks your weekly progress (Monday - Friday). A pace engine dynamically calculates the required daily workload. Upon hitting the goal, an audio tone is synthesized.

### Advanced Input & Operations

- **Smart Auto-Formatting Normalizers**: Speed-type inputs with auto-select. E.g., `8` or `08` becomes `08:00`; `1245` becomes `12:45`.
- **Intelligent Date Parser**: Use relative keywords (`t` or `today` for today, `y` for yesterday, `-3` for 3 days ago).
- **Shift Operations**: Edit dates, work hours, or notes. Safely delete shifts, copy individual text summaries, or copy the entire filtered logbook into a tabular text report.

---

## ⚙️ Technical Details

- **Core Technologies:** HTML5, CSS3 (Vanilla), JavaScript (Vanilla, ES6+).
- **Storage:** IndexedDB and LocalStorage for persistent local data.
- **Performance:** DOM Virtualization is used to render the logbook efficiently without lagging the browser.
- **Audio:** Native Web Audio API is used for synthesizing success tones.

### Development & Build Process

The application is engineered as a self-contained single file to maximize portability. 
- **`utils.js`**: Contains pure utility functions for development and testing.
- **`sync.bat` & `sync_utils.ps1`**: Automated build scripts that inline the contents of `utils.js` directly into `index.html` and `index.test.html`. By running `sync.bat`, the app compiles into a 100% self-contained file.

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome!

---

## 📄 License

This project is open-source and licensed under the [MIT License](LICENSE).
