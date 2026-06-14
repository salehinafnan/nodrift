<div align="center">

# nodrift

**Zero backend. Zero latency. Total privacy. One file.**

![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)
![Lines](https://img.shields.io/badge/Lines-14%2C152-blueviolet?style=flat-square)
![Size](https://img.shields.io/badge/Size-526KB-orange?style=flat-square)
![Storage](https://img.shields.io/badge/Storage-IndexedDB_%2B_LocalStorage-success?style=flat-square)
![Deps](https://img.shields.io/badge/Dependencies-0-brightgreen?style=flat-square)

</div>

---

## Why This Exists

Most time trackers are either bloated SaaS tools that harvest your data, or barebones stopwatches that break the moment you close the tab. This is neither.

The **Work Hour Tracker** is a self-contained, single-file web application that runs entirely in your browser. It tracks active work hours, rest breaks, daily goals, and weekly workloads with analytical precision — all while storing everything locally on your machine. No accounts. No servers. No subscriptions. Just open `index.html` and start working.

---

## Table of Contents

- [Getting Started](#getting-started)
- [Core Time Tracking](#core-time-tracking)
- [Command Palette (HUD)](#command-palette-hud)
- [Goals & Weekly Analytics](#goals--weekly-analytics)
- [Insights & Heatmap](#insights--heatmap)
- [Virtual Logbook](#virtual-logbook)
- [Smart Input System](#smart-input-system)
- [Theme Engine (4 Themes)](#theme-engine-4-themes)
- [Leave Management](#leave-management)
- [Safety & Integrity](#safety--integrity)
- [Data Portability](#data-portability)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [Timezone Support](#timezone-support)
- [Architecture & Performance](#architecture--performance)
- [Development & Build System](#development--build-system)
- [License](#license)

---

## Getting Started

There are no dependencies. No `npm install`. No build step for end users.

1. **Download** or clone this repository.
2. **Open `index.html`** in any modern browser (Chrome, Firefox, Edge, Safari).
3. Press `Spacebar` to start tracking.

> **Self-Hosting:** Deploy the folder to Vercel, Netlify, or GitHub Pages. Browser storage is origin-bound, so use the **Export/Import JSON** feature when migrating between domains.

---

## Core Time Tracking

The app maintains two independent, wall-clock-based timers — one for **Work** and one for **Break** — powered by a dual-clock system using both `Date.now()` and `performance.now()` for drift-resistant accuracy.

- **Start/Stop:** Click the Work or Break button, or press `Spacebar` to toggle between modes.
- **Log a Shift:** Press `S` to open the submission modal. Add notes, tags, or task descriptions before archiving.
- **Undo Submit:** Accidentally logged a shift? An undo toast appears immediately after submission, letting you revert the entry and restore your prior session state.
- **Ghost Shift Protection:** If a shift is under 60 seconds, the app prompts you to confirm before saving — preventing accidental micro-logs from polluting your history.
- **Dynamic Browser State:** The page title and favicon update in real-time to reflect your current mode: green for *Working*, red for *Break*, yellow for *Paused*, gray for *Idle*.
- **Note Suggestions:** When adding shift notes, the app surfaces an autocomplete datalist of your recently used unique notes for faster logging.

---

## Command Palette (HUD)

Press `/` to open the **Command Palette** — a full-featured, fuzzy-search command center inspired by VS Code and Raycast.

### Core Commands

| Command | What It Does |
| :--- | :--- |
| `start work` / `start break` | Start or resume the corresponding timer |
| `stop work` / `stop break` | Pause the corresponding timer |
| `add log` | Open the manual entry modal |
| `nav dashboard` / `logbook` / `insights` | Switch between tabs |
| `search [query]` | Jump to Logbook with a search filter applied |
| `note [text]` | Append a note to the currently active session |
| `report` | Copy a formatted daily status report to clipboard |
| `help` | Open the help guide |

### Goal & Theme Commands

| Command | What It Does |
| :--- | :--- |
| `goal [value]` | Set daily goal (e.g., `goal 8h 30m` or `goal 8.5`) |
| `+15m` / `-15m` | Adjust goal by 15 minutes |
| `theme onyx` / `cobalt` / `sf dark` / `sf light` | Switch themes with **live preview** on arrow keys |

### NLP Write Engine

Type natural language to create log entries without touching any form:
```
add yesterday 9am to 5pm worked on dashboard redesign
add -3 10:00 to 18:30 backend API integration
```
The engine parses relative dates, 12h/24h time formats, and freeform note text in a single command.

### NLP Leave Engine

```
leave sick tomorrow
leave casual 06/15
```
Books a leave entry with smart date parsing and type detection.

### Data & Export Commands

| Command | What It Does |
| :--- | :--- |
| `csv` | Export your log history as a CSV spreadsheet |
| `backup` | Download a full JSON backup of all data |
| `restore` | Import a JSON backup |
| `json` | Copy raw JSON data to clipboard |
| `wipe` | Factory reset (with confirmation) |
| `export week` / `month` | Generate a timesheet invoice (CSV + email draft) |

### Search & Metrics

| Command | What It Does |
| :--- | :--- |
| `log [query]` | Search past logs with advanced filters (e.g., `log this month over >5h`) |
| `metrics week` / `month` / `today` / `all` | Calculate and display aggregate work statistics |
| `edit [search]` | Interactive log edit engine for quick modifications |
| `g [query]` | Search Google directly from the palette |

### Smart Behaviors
- **Context-Aware Ordering:** Commands are ranked based on your current state (working, on break, or idle).
- **Built-in Calculator:** Type any math expression (e.g., `8.5 * 22`) and get the result instantly, with a click to copy.
- **Live Timer Display:** Your current active session duration is shown in real-time within the palette.
- **Fuzzy Scoring:** A custom scoring algorithm matches partial input, rewards consecutive character matches, and boosts word-boundary hits.

---

## Goals & Weekly Analytics

### Daily Work Target
- Set your daily goal via the header input, preset buttons, or the command palette.
- **Flexible Input:** Type `8`, `8h 30m`, `8.5`, `8:30`, or `830` — the parser handles all formats.
- **Customizable Presets:** Two preset buttons (default 6h, 10h). **Double-click** any preset to customize its value. Presets persist across sessions.
- **±15m Adjustments:** Fine-tune your target incrementally with dedicated buttons or `Alt+=` / `Alt+-`.

### Weekly 40-Hour Engine
- Tracks your cumulative weekly progress from Monday through Friday against a fixed 40-hour goal.
- **Segmented Progress Bar:** Five animated segments representing Mon–Fri. Today's segment fills cumulatively by summing all completed shifts with the current live session.
- **Dynamic Pace Indicator:** If you're behind, the engine calculates the exact hours/day needed to hit 40 hours. Example: *"Pace Needed: 5h 30m / day (to hit 40h)"*.
- **Estimated EOD:** Displays the projected end-of-day time based on your current pace and remaining goal.
- **Goal Reached Celebration:** When you hit your daily goal, a toast notification appears and an **880Hz sine wave tone** is synthesized via the Web Audio API.

---

## Insights & Heatmap

Switch to the **Insights** tab (`Alt+1`) for a deep analytical view of your work patterns.

- **Weekly Breakdown Table:** A detailed Mon–Sun table showing work hours, break time, and goal status per day, including leave days.
- **Week Navigation:** Browse historical weeks with `[` / `]` keys, or press `H` to jump to the current week.
- **Activity Heatmap:** A GitHub-style contribution grid that maps your work intensity across months. Color intensity scales based on work hours relative to your goal. Leave days are rendered distinctly. Click to expand into a full-screen heatmap modal.
- **Streak Counter:** Tracks your consecutive work day streak (days where you hit at least 80% of your goal).

---

## Virtual Logbook

The logbook is engineered to handle **thousands of entries** without browser lag.

### DOM Virtualization
Instead of rendering every row, the logbook uses a custom virtualized windowing system driven by `requestAnimationFrame`. Only rows visible in the viewport are rendered — giving you O(1) scroll performance regardless of history size.

### Filtering & Search
- **Text Search:** Filter by note content, tags, or descriptions.
- **Status Filter:** Show only entries that were OVER or UNDER the daily goal.
- **Duration Bounds:** Filter by hours worked (e.g., `>5h`, `<2.5h`).
- **Date Range:** Filter by this week, this month, last month, today, yesterday, or custom `MM/YYYY`.
- **Saved Filter Views:** Save and load named filter configurations for one-click access to your most-used views.

### Entry Operations
- **Edit:** Modify dates, work hours, break times, or notes on any historical entry.
- **Delete:** Remove entries with a double-confirmed safety modal.
- **Copy:** Copy a single shift as a formatted text summary, or copy the entire filtered logbook as a tabular report.
- **Manual Entry:** Retroactively log a forgotten shift with full date/time parsing support.
- **Keyboard Navigation:** Use `↑`/`↓` to select rows, `E` to edit, `D` to delete, `C` to copy, `Enter` to view notes.

---

## Smart Input System

Every input field in the app is built for speed, featuring auto-select on focus and intelligent normalization on blur.

### Time Inputs
| You Type | You Get |
| :--- | :--- |
| `8` or `08` | `08:00` |
| `930` | `09:30` |
| `1245` | `12:45` |
| `2359` | `23:59` (max ceiling) |

### Goal Inputs
| You Type | You Get |
| :--- | :--- |
| `8` | `8h 0m` |
| `830` | `8h 30m` |
| `8.5` | `8h 30m` |
| `8:30` | `8h 30m` |

### Date Inputs
| You Type | You Get |
| :--- | :--- |
| `t` or `today` | Today's date (`MM/DD/YY`) |
| `y` or `yesterday` | Yesterday's date |
| `-3` | 3 days ago |
| `5/18` | `05/18/{currentYear}` |
| `051826` | `05/18/26` |
| `18` | `{currentMonth}/18/{currentYear}` |

Calendar boundaries are validated dynamically, including leap-year calculations (e.g., `02/30/24` → `02/29/24`).

### Live Preview Tooltips
As you type in date, time, and goal fields, a tooltip renders a live preview of the parsed value — so you can see exactly what the app understood before you commit.

---

## Theme Engine (4 Themes)

Press `Alt+T` to cycle through themes, or use the command palette for instant switching with **live preview** on arrow keys.

| Theme | Description |
| :--- | :--- |
| **SF Dark** *(default)* | Apple-inspired system charcoal. Clean, neutral, and professional. |
| **Onyx Black** | Pitch-black OLED mode. Maximum contrast, zero wasted pixels. |
| **Cobalt Glass** | Deep translucent blue with glassmorphic panel overlays. |
| **SF Light** | Bright system light mode for well-lit environments. |

All themes are built on a comprehensive CSS custom property system (`--page-bg`, `--panel-bg`, `--accent-*`, `--border-*`, etc.) ensuring pixel-perfect consistency across every UI element.

---

## Leave Management

Track vacation days, sick leave, and public holidays alongside your work data.

- **Leave Types:** Casual, Sick, Public Holiday — each with a distinct color-coded badge.
- **Leave Modal:** Add or remove leave dates through a dedicated management interface.
- **HUD Integration:** Type `leave sick tomorrow` or `leave casual 06/15` in the command palette.
- **Analytics Integration:** Leave days appear in the weekly breakdown table and the activity heatmap, ensuring your analytics remain accurate even when you're away.

---

## Safety & Integrity

### Idle Lockout
The app monitors mouse clicks, scrolls, and keypresses. When physical inactivity exceeds a configurable threshold (default: 60 minutes), a lock screen modal appears with three options:
- **Count as Work** — attribute idle time as productive hours.
- **Count as Break** — reclassify as rest time.
- **Discard** — remove the idle period from your session entirely.

Two detection modes: *inactivity* (no user input) and *system* (OS sleep/suspend detected via wall-clock vs. monotonic clock discrepancy).

### Multi-Tab Sync Lockout
Opening the app in multiple tabs risks database corruption. The app uses a `BroadcastChannel` + localStorage lease mechanism to ensure only one active master tab writes to the database. Conflicting tabs are locked out with a modal.

### Additional Safeguards
- **Window Leave Protection:** `beforeunload` and `pagehide` handlers prevent accidental closure and force-sync state.
- **Overnight Shift Mapping:** Shifts spanning midnight are preserved in the starting day's record.
- **Ghost Shift Protection:** Sub-60-second shifts trigger a confirmation prompt.
- **Emergency Backup:** The last 100 logs are synchronously written to `localStorage` on every save. On startup, the app cross-references this backup against IndexedDB and recovers any missing entries.
- **State Corruption Recovery:** `loadState()` handles parse failures gracefully, migrates legacy formats, sanitizes future-dated timestamps, and nullifies stale monotonic clock values.
- **XSS Protection:** All user-generated content is rendered through `escapeHTML()`.

---

## Data Portability

| Action | Description |
| :--- | :--- |
| **Export JSON** | Full backup: state, logs, goals, presets, leaves, filter views, and settings. |
| **Import JSON** | Smart merge with deduplication and conflict resolution by `lastModified` timestamp. Active sessions are protected (settings-only merge during live tracking). |
| **Export CSV** | Spreadsheet with Date, Login/Logout, Work Duration, Decimal Hours, Break, Net Delta, and Notes. |
| **Factory Reset** | Double-confirmed wipe of IndexedDB + localStorage. |
| **Auto-Backup** | Optionally auto-export a JSON backup on every shift submission. |
| **Auto-Email** | Optionally draft a Gmail compose with your daily report on submission via `Ctrl+S`. |

---

## Keyboard Shortcuts

### Global

| Key | Action |
| :--- | :--- |
| `Spacebar` | Toggle Work / Break (or start if idle) |
| `S` | Open Submit Shift modal |
| `/` | Open Command Palette |
| `?` | Open Help modal |
| `Ctrl+S` / `Cmd+S` | Export JSON backup + open Gmail compose |
| `Alt+T` | Cycle themes |
| `Alt+1` | Switch to Insights tab |
| `Alt+2` | Switch to Logbook tab |
| `Alt+K` | Focus Logbook search input |
| `Alt+N` | Open Manual Log Entry modal |
| `Alt+=` / `Alt+-` | Adjust daily goal ±15 min |
| `Escape` | Close modals / deselect log entry |

### Insights Tab

| Key | Action |
| :--- | :--- |
| `[` or `Alt+←` | Previous week |
| `]` or `Alt+→` | Next week |
| `H` | Jump to current week |

### Logbook Navigation

| Key | Action |
| :--- | :--- |
| `↑` / `↓` | Select previous / next log entry |
| `Enter` or `N` | View note of selected entry |
| `E` | Edit selected entry |
| `D` / `Delete` / `Backspace` | Delete selected entry |
| `C` | Copy selected entry to clipboard |

---

## Timezone Support

- **Configurable Primary Timezone:** Selectable via dropdown, persisted to localStorage.
- **Preset Shortcuts:** PST, EST, CST available as quick-select pills and HUD commands.
- **PST-Based Calendar Logic:** The app's date boundaries and "today" calculations are anchored to your configured timezone, not the browser's local time.
- **Estimated EOD Formatting:** End-of-day projections are rendered using the active timezone's formatter.

---

## Architecture & Performance

| Aspect | Detail |
| :--- | :--- |
| **Type** | Single-file monolith (HTML + CSS + JS, fully inlined) |
| **Lines of Code** | 14,152 |
| **File Size** | ~526 KB |
| **CSS** | ~5,500 lines of inline styles |
| **JavaScript** | ~8,500 lines of application logic |
| **External Dependencies** | 0 |
| **Storage Layer** | localStorage (state, settings) + IndexedDB (logs) |
| **Concurrency** | BroadcastChannel + localStorage lease for multi-tab safety |
| **Timer Engine** | Web Worker (inline blob) for background tick accuracy |
| **Scroll Performance** | DOM Virtualization with `requestAnimationFrame` rendering |
| **Rendering** | Throttled DOM write cache to minimize reflows |
| **CSS Containment** | `contain: layout paint` on logbook for rendering isolation |
| **Typography** | Native system font stack (SF Pro, Segoe UI, Roboto) — zero external font requests |
| **Icons** | Inline SVG `<defs>` with `<use>` references — zero network requests |
| **Responsive** | `font-size: clamp(14px, 1vw, 20px)` on root, touch-optimized dropdowns with backdrop scrims |

---

## Development & Build System

The application is engineered as a **100% self-contained single file** for maximum portability. During development, utility functions are maintained in a separate file for testability:

- **`utils.js`** — Pure functions (`formatDuration`, `parseTime`, `escapeHTML`, `parseGoalTimeStr`, `hudFuzzyScore`, `debounce`, etc.) separated from DOM logic for isolated unit testing.
- **`index.test.html`** — Test harness that exercises the utility functions.
- **`sync.bat`** / **`sync_utils.ps1`** — Automated build scripts. Double-click `sync.bat` to inline the contents of `utils.js` into both `index.html` and `index.test.html`, compiling the app back into its self-contained form.

This architecture lets you develop and test in a modular environment while shipping a single file with zero external dependencies.

---

## License

This project is open-source and licensed under the [MIT License](LICENSE).
