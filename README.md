# Work Hour Tracker — User Guide & Operational Manual

Welcome to the **Work Hour Tracker**, a premium, high-performance, local-first client-side web application. It is designed to track active work hours, rest breaks, and weekly workloads with analytical precision. 

The entire application runs **locally in your web browser** and does not communicate with any external backend servers. Your data belongs entirely to you.

---

## Table of Contents
1. [Core UI & Theme Customs](#1-core-ui--theme-customs)
2. [Time-Tracking & Session Controls](#2-time-tracking--session-controls)
3. [Keyboard Shortcuts](#3-keyboard-shortcuts)
4. [Safety & Synchronization Safeguards](#4-safety--synchronization-safeguards)
5. [Daily Goals & The Weekly Analytics Engine](#5-daily-goals--the-weekly-analytics-engine)
6. [High-Performance Virtual Logbook](#6-high-performance-virtual-logbook)
7. [Data Portability & Backups](#7-data-portability--backups)
8. [Self-Hosting & Operations](#8-self-hosting--operations)

---

## 1. Core UI & Theme Customs

The interface is engineered to offer visual clarity, dynamic transitions, and modern glassmorphism. You can toggle between two curated themes using the theme selector at the top-right:

* **Midnight (Premium Noir)**: A deep black interface with optimized contrast for low-light environments, eliminating eye strain during long tracking sessions.
* **Glass (Frosted Glassmorphic)**: A modern aesthetic overlaying translucent panes over vibrant, ambient gradient backdrops.

---

## 2. Time-Tracking & Session Controls

The app uses two main counters to track your day: the **Work Timer** (active productive hours) and the **Break Timer** (rest or pause durations).

### Standard Tracking Loop
1. **Start Tracking**: Click the **Work** button (or press `Spacebar`) to initiate your shift. The main timer lights up green and begins counting.
2. **Taking Breaks**: Click the **Break** button (or press `Spacebar`) when pausing tasks. The work timer freezes, and the break timer activates (rendered in red) to track your rest duration.
3. **Submitting a Shift**: When your workday is complete, click **Log Shift** (or press the `S` key). A modal pops up allowing you to add custom shift notes (e.g., tags, task descriptions) before finalizing the shift.

---

## 3. Keyboard Shortcuts

Maximize operational speed by utilizing global hotkeys. Keyboard control is disabled when you are actively typing inside input fields, dropdowns, or textareas:

| Hotkey | Action | Operational Detail |
| :--- | :--- | :--- |
| `Spacebar` | **Toggle Timer Mode** | Instantly switches active state between **Work** and **Break** modes. |
| `S` | **Open Log Shift Modal** | Opens the shift submission window to archive your current tracking session. |
| `Escape` | **Close Modals** | Instantly exits any open modal (Edit, Manual Entry, Note, or Submission). |

---

## 4. Safety & Synchronization Safeguards

To ensure your local database remains perfect and uncorrupted, the app features multiple built-in automated safeguards:

* **Idle Lockout**: Auto-detects physical inactivity (absence of mouse clicks, scrolls, or keypresses). Past the idle threshold, the app automatically triggers a lock screen overlay, pauses active timing, and displays the exact duration you were away so you can adjust your log accurately.
* **Window Leave Protection**: A warning popup (`beforeunload`) prevents accidental page closure, browser tab exits, or reloads while a timer is actively running.
* **Overnight Shift Mapping**: If you work a shift spanning across midnight (e.g., 11:00 PM Monday to 4:00 AM Tuesday), the app preserves the entire shift inside Monday’s record to avoid fragmented or divided reports.
* **Multi-Tab Sync Lockout**: If you open the application in multiple browser tabs simultaneously, a conflict lockout modal activates. This prevents write race conditions and ensures only one active master tab updates the local database.

---

## 5. Daily Goals & The Weekly Analytics Engine

The tracker integrates an active workload evaluator to keep you on schedule:

### Daily Work Target
* Adjust your daily work goal directly at the header using the **Goal** hours and minutes input boxes.
* Input fields are sanitized: they reject letters, and minutes automatically clamp within a strict `0–59` range when you click away.

### Weekly 40-Hour Engine & Pace Tracker
* The tracker monitors a fixed **40-hour work week goal** from Monday through Friday.
* **Weekly Segment Bars**: The UI renders five progress segments representing Monday to Friday. The current day is highlighted, and segments fill up dynamically based on your daily goal achievement.
* **Dynamic Daily Pace Indicator**: If you are behind on your weekly 40-hour goal, the pace engine dynamically calculates the required daily workload:
  * *Example display:* `Pace Needed: 5h 30m / day (to hit 40h)`
  * Once the 40-hour goal is reached, the status text turns green and displays your total overtime.
* **Synthesized Success Tone**: Upon crossing the 40-hour weekly milestone, the app uses the browser's native **Web Audio API** to synthesize an 880Hz audio tone to celebrate your achievement.

---

## 6. High-Performance Virtual Logbook

The logbook handles extensive history smoothly by incorporating custom visual and database utilities:

* **DOM Virtualization**: Instead of lagging the browser by rendering thousands of rows, the logbook uses virtualized windowing to only render rows currently visible in your viewport.
* **Advanced Multi-Criteria Filtering**: Open the filters header to search and narrow down shifts:
  * **Time Range**: Filter log logs between custom start and end dates.
  * **Search Notes**: Type queries to perform text matching on note tags or descriptions.
  * **Status**: Filter by goal status (`OVER` daily goal or `UNDER` daily goal).
  * **Timezone**: Switch timezone rendering on the fly to review logs in alternate zones.
* **Shift Operations**:
  * **Edit Shift**: Click the Edit icon on any row to modify dates, work hours (`HH:MM`), break times, or notes.
  * **Delete Shift**: Safely delete shifts with a double-confirmed pop-up warning.
  * **Copy Shift Text**: Copies a single shift summary formatted as plain text to your clipboard.
  * **Copy Log Table**: Copies the entire filtered logbook into a tabular text report.
  * **Manual Shift Entry**: Retroactively log a forgotten shift by clicking the **Manual Entry** button.
  * **Smart Auto-Formatting Normalizers (Blur Event)**:
    * **Frictionless Time & Goal Inputs**: The Add Manual Shift, Edit Shift, and Header Daily Goal forms support speed-typing inputs with auto-select on focus (`onfocus="this.select()"`). Typing shorthands automatically normalizes on focus exit:
      * *Shift Times*: `8` or `08` $\rightarrow$ `08:00`; `930` $\rightarrow$ `09:30`; `1245` $\rightarrow$ `12:45` (with a `23:59` maximum ceiling limit).
      * *Daily Goal Field*: `8` or `800` $\rightarrow$ `8h 0m`; `830` $\rightarrow$ `8h 30m` (always balanced with visible minutes, hours lack leading zero).
    * **Intelligent Date Parser**: The date input automatically resolves partial, shorthand, and relative entries on focus exit:
      * *Relative Keywords*: `t` or `today` $\rightarrow$ today's date (`MM/DD/YY`); `y` or `yesterday` $\rightarrow$ yesterday's date; `-N` (e.g. `-3`) $\rightarrow$ date from $N$ days ago.
      * *Partial Delimiters*: `5/18` $\rightarrow$ pads to `05/18/currentYear`.
      * *Digit Shorthand*: `051826` $\rightarrow$ `05/18/26`; `18` $\rightarrow$ `currentMonth/18/currentYear`.
      * *Calendar Boundaries*: Dynamic day validation correctly clamps values based on month limits and leap-year calculations (e.g., `02/30/24` $\rightarrow$ `02/29/24`).

---

## 7. Data Portability & Backups

You own your tracking database. You can manage your backups locally with zero external dependencies:

* **Export JSON Backup**: Click **Export JSON** to download your entire operational state (settings, custom goals, active timers, and complete log history) as a `.json` backup file.
* **Import JSON Backup**: Restore or migrate your history to another browser or device by importing your backup file.
* **Export CSV Spreadsheet**: Generate a spreadsheet-compatible `.csv` data table containing:
  * `Date`, `Login Time`, `Logout Time`, `Work Duration`, `Decimal Work Hours`, `Break Duration`, `Net Work Delta`, and `Notes`.
* **Factory Reset**: A secure, double-confirmed button to erase all local logs and restore the tracker to factory settings.

---

## 8. Self-Hosting & Operations

### Browser Origin Isolation
Because the application stores data locally inside the browser's **IndexedDB** and **LocalStorage**, the database is strictly tied to the **domain name** (origin).
* **Local File**: `file:///c:/.../index.html` has its own isolated database.
* **Hosted Site**: `https://your-tracker.vercel.app` has its own isolated database.
* *Migration Tip:* When moving from the local file to your Vercel URL, click **Export JSON** on your local file, open your new Vercel URL, and click **Import JSON** to restore your data.

---

## 9. License

This project is open-source and licensed under the [MIT License](LICENSE).

