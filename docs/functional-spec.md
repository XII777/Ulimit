# Ulimit — Functional Specification & Technical Requirements

**Product:** Ulimit — digital wellbeing / distraction-control application (Android)
**Document scope:** Navigation overlay rules, Limits dashboard, focus-session tracking, and the Focus history page.
**Status:** Implemented — this document specifies the behavior the shipped build must satisfy and serves as the acceptance baseline for regressions.

---

## 1. Introduction

### 1.1 Purpose

This document defines the functional and technical requirements for four behaviors of the Ulimit productivity application:

1. Layering of pop-up notifications and modal windows relative to the navigation bar (FR-1).
2. The Limits dashboard "page load" view: fetching all installed applications with names and icons, sorted by usage time in descending order (FR-2).
3. Tracking and recording the duration of individual focus sessions (FR-3).
4. The Focus history page: a tile-based aggregation of completed sessions with accumulated totals and per-session metadata (FR-4).

### 1.2 Intended audience

Engineering, QA, and documentation consumers who need an unambiguous behavioral contract for these features.

### 1.3 Technology context (normative for technical requirements)

| Layer              | Technology |
| ------------------ | ---------- |
| UI / state         | Flutter + Riverpod |
| Local database     | SQLite via Drift (schema v2) |
| Usage source       | `UsageStatsManager`-backed events via AccessibilityService (`UsageEventBridge`) |
| App catalog        | `PackageManager` via the `enforcement` platform channel |
| Focus persistence  | `focus_sessions` table (Drift) |
| Navigation         | `go_router` shell with a floating pill navigation bar (`NavShell`) |

---

## 2. Definitions

| Term | Definition |
| ---- | ---------- |
| **Navigation bar (nav bar)** | The floating, pill-shaped bottom navigation rendered by `NavShell` across all five primary destinations. |
| **Modal surface** | Any transient overlay the app presents above page content: `showModalBottomSheet`, `showDialog`/`AlertDialog`, `SnackBar`, in-app banner, or a system dialog triggered by the app. |
| **Installed application** | Any package with a launcher activity, excluding Ulimit itself. |
| **Usage time** | Aggregated foreground seconds per package for the current local day (`AppUsage.foregroundSeconds` where `day == startOfDay(now)`). |
| **Focus session** | One row in `focus_sessions`: a user-initiated, time-boxed distraction-control period. |
| **Completed session** | A session whose `ended_at` is set and `completed` flag is true. |

---

## 3. FR-1 — Overlay layering rule

### 3.1 Requirement

All pop-up notifications and modal windows presented by the application **MUST render on a layer above the navigation bar**. The navigation bar must never visually overlap, obscure, or intercept interaction with an active modal surface.

### 3.2 Functional behavior

- **FR-1.1 (Mandatory)** Bottom sheets must cover the nav bar. When a modal bottom sheet opens, its container extends to the bottom screen edge; the nav bar is either fully covered by the sheet's scrim or pushed visually behind it. The sheet's safe-area padding accounts for the system gesture inset, not the nav bar's position.
- **FR-1.2 (Mandatory)** Dialogs (`AlertDialog`, custom dialogs) must render centered above the nav bar. The dialog scrim must dim the nav bar together with page content, making it non-interactive while the dialog is open.
- **FR-1.3 (Mandatory)** Snackbars must appear above the nav bar's top edge with a minimum clearance of 8 dp. A snackbar must never render underneath or on top of the nav pill.
- **FR-1.4 (Mandatory)** While any modal surface is open, taps on the nav bar must be blocked (absorbed by the modal barrier), and the nav bar must not update its active tab as a result of gestures over the barrier.
- **FR-1.5 (Mandatory)** The nav bar must remain mounted and visually unchanged behind the modal barrier; modal open/close must not rebuild or re-animate the nav bar.
- **FR-1.6 (Should)** The system gesture-navigation inset must be respected by both the nav bar (bottom clearance) and modal surfaces (bottom safe-area padding) so neither content nor controls collide with system gestures.

### 3.3 Technical requirements

- **TR-1.1** The application uses `ShellRoute` so the nav bar is a sibling of, not an ancestor of, routed pages. Modal routes pushed via the root navigator stack above the shell naturally z-order above it.
- **TR-1.2** Bottom sheets are opened with `isScrollControlled: true` and sized against the full screen so the sheet body reaches the bottom edge, layered above the shell.
- **TR-1.3** Snackbars must specify a bottom margin that accounts for nav-bar height + gesture inset (`MediaQuery.paddingOf(context).bottom + navBarClearance`).
- **TR-1.4** The enforcement overlay (`UlimitAccessibilityService`, `TYPE_ACCESSIBILITY_OVERLAY`) is a system-layer surface and is out of scope for this rule; it must, however, also cover the nav bar when visible.

### 3.4 Acceptance criteria

| ID | Criterion |
| -- | --------- |
| AC-1.1 | Opening the app selector bottom sheet from any tab covers the nav pill entirely. |
| AC-1.2 | A dialog opened from Settings dims the nav pill; tapping where the pill was does not switch tabs. |
| AC-1.3 | A snackbar shown from the Restrictions screen renders fully above the pill with ≥ 8 dp clearance. |
| AC-1.4 | Dismissing a modal restores the nav pill to its pre-modal state with no visual flicker or rebuild animation. |

---

## 4. FR-2 — Limits dashboard: page-load view

### 4.1 Requirement

The Limits screen **MUST** present, on load, the set of all installed applications together with their display names and icons, **sorted in descending order by today's usage time** (highest usage first).

### 4.2 Functional behavior

- **FR-2.1 (Mandatory)** On first load of the Limits screen, the app requests the installed-application catalog from the platform layer (`PackageManager` query for launcher activities, excluding Ulimit itself).
- **FR-2.2 (Mandatory)** Each entry renders the app's display name and its launcher icon. Icons are delivered as PNG bytes over the platform channel, cached per package for the session, and decoded once. If an icon is unavailable, a neutral fallback (first letter on a neutral surface) renders instead — never a blank space and never a crash.
- **FR-2.3 (Mandatory)** Sorting: entries with usage data are ordered by `usageTime` descending. Apps with zero usage for today sort after all used apps, alphabetically by display name.
- **FR-2.4 (Mandatory)** Usage time is read from today's `app_usage` rows and joined live: any foreground-time change reflected in the database updates the ordering without an app restart.
- **FR-2.5 (Mandatory)** The configured surfaces (per-app limits, restriction groups) render above the catalog and must not block its load: the catalog loads asynchronously with a non-blocking indicator.
- **FR-2.6 (Should)** A search field filters the catalog by display name (case-insensitive) without refetching from the platform layer.
- **FR-2.7 (May)** Pull-to-refresh invalidates the catalog to pick up newly installed/removed applications.

### 4.3 Technical requirements

- **TR-2.1** App catalog is provided by `appsCatalogProvider` (`EnforcementChannel.getInstalledApps`), which returns `[{package, name, icon: PNG bytes}]`. The catalog is loaded once per app run and kept alive; per-screen ordering is derived, not refetched.
- **TR-2.2** Usage ordering is derived by joining the catalog with `todayUsageByPackageProvider` (live Drift stream of `{package: seconds}`).
- **TR-2.3** Icon bytes are exposed via `appIconProvider` (FutureProvider.family keyed by package) so multiple lists (Limits, app selector, Home) share a single decode per package.
- **TR-2.4** Sorting is a pure function over (catalog, usage) and must be stable across rebuilds; no network or platform-channel call may occur during a sort pass.
- **TR-2.5** Large catalogs (200+ apps) must render via `ListView.builder` (lazy) with spring physics; no unbounded `Column` of app rows is permitted.

### 4.4 Acceptance criteria

| ID | Criterion |
| -- | --------- |
| AC-2.1 | With usage data present, the top row is the app with the highest recorded foreground time today. |
| AC-2.2 | An app with 0 seconds today never appears above an app with > 0 seconds. |
| AC-2.3 | Killing and relaunching the app preserves identical ordering (deterministic sort). |
| AC-2.4 | When usage updates mid-session (user returns from another app), order re-sorts on the next screen observation without manual refresh. |
| AC-2.5 | For an app with a missing icon, the fallback letter renders and the row remains interactive. |

---

## 5. FR-3 — Focus session tracking

### 5.1 Requirement

The system **MUST** track and persist the duration of each individual focus session as a first-class, locally persisted record that survives process death, app restarts, and device restarts.

### 5.2 Functional behavior

- **FR-3.1 (Mandatory)** Starting a focus session records: label (user-chosen), start timestamp, planned duration, blocked-package list, and the active policy flags (pause notifications, block internet, block websites, invincible mode).
- **FR-3.2 (Mandatory)** A running session is defined as the newest `focus_sessions` row with `ended_at == null`. At most one session may run at a time; starting a new session finalizes any stale open row first.
- **FR-3.3 (Mandatory)** The remaining time shown during a session is derived from real timestamps (`started_at + planned_seconds − now`), never from an in-memory countdown as the source of truth.
- **FR-3.4 (Mandatory)** When the planned end time passes, the session is marked `completed = true` with `ended_at = started_at + planned_seconds`. This finalization must be timestamp-driven: it must occur even if the app was killed, backgrounded, or the device rebooted before the end time — the next evaluation after relaunch back-fills the row.
- **FR-3.5 (Mandatory)** Ending early records `ended_at = now` and `completed = false`. If the session is invincible, early ending requires successful biometric/device-credential authentication first.
- **FR-3.6 (Mandatory)** Session duration is reported as `ended_at − started_at` for finished sessions, and live `now − started_at` for a running one.
- **FR-3.7 (Should)** Session events drive enforcement: the blocked-package list and policies of the running session feed the restriction engine and the native enforcement snapshot for the session's lifetime.

### 5.3 Technical requirements

- **TR-3.1** Persistence uses the `focus_sessions` Drift table; all mutations go through `FocusController` (Riverpod), never through widgets directly.
- **TR-3.2** `activeFocusSessionProvider` is a live Drift watch on the newest open row; `finalizeIfDue()` is invoked on the global 15-second evaluation tick.
- **TR-3.3** The enforcement snapshot pushed to the native layer includes the running session's `untilMillis` and policy set so native enforcement (overlay, VPN, notification holding) stays correct without the app on screen.
- **TR-3.4** Clock changes: session math must use wall-clock timestamps consistently; a session must never display negative remaining time (clamped to zero).

### 5.4 Acceptance criteria

| ID | Criterion |
| -- | --------- |
| AC-3.1 | Start a 25-minute session → kill the app → relaunch after 26 minutes → the session appears in history as completed with a 25-minute duration. |
| AC-3.2 | Start a session, end it early → history shows duration < planned and marks it incomplete. |
| AC-3.3 | Remaining time on the running screen equals `planned − elapsed` within ±1 s of a reference clock. |
| AC-3.4 | Airplane-mode session: tracking, completion, and history are fully functional (no connectivity dependency). |
| AC-3.5 | Invincible session: the "end early" action fails without successful authentication, and succeeds after it. |

---

## 6. FR-4 — Focus history page

### 6.1 Requirement

The Focus screen **MUST** aggregate all completed focus sessions into a tile-based history view, showing the total accumulated focus time and per-session metadata including start and end date and time.

### 6.2 Functional behavior

- **FR-4.1 (Mandatory)** The history lists completed sessions (`ended_at != null`) ordered by start time, newest first.
- **FR-4.2 (Mandatory)** Each tile displays: session label, duration (`ended_at − started_at`), start date-time, end date-time, and completion state (completed / ended early).
- **FR-4.3 (Mandatory)** The view shows the total accumulated time across the listed sessions (sum of durations), plus the count of today's completed sessions.
- **FR-4.4 (Mandatory)** All times render in the device's local timezone and locale-aware clock format; the date is rendered unambiguously (e.g. "Mon, 30 Aug").
- **FR-4.5 (Mandatory)** Sessions completed through back-fill (FR-3.4) appear identically to interactively completed ones.
- **FR-4.6 (Should)** An empty state ("No sessions yet") with guidance is shown when no completed sessions exist; no blank page.
- **FR-4.7 (May)** Sessions can be deleted individually; deletion updates totals immediately.

### 6.3 Technical requirements

- **TR-4.1** History is provided by `focusHistoryProvider` (Drift watch, ordered by `started_at` desc, reasonable page limit). Tiles are lazily built.
- **TR-4.2** Totals derive from the same source rows as the tiles — a single source of truth; totals must never be cached separately.
- **TR-4.3** Duration and time formatting reuse the engine's formatting utilities (`formatClock`, `formatDurationShort`) so Focus history and the Home dashboard can never disagree.
- **TR-4.4** The page uses the standard spring scroll physics and renders above the nav bar per FR-1.

### 6.4 Acceptance criteria

| ID | Criterion |
| -- | --------- |
| AC-4.1 | With three completed sessions of 10, 15, and 25 minutes, the total reads 50 minutes. |
| AC-4.2 | Each tile's start/end date-times match the values recorded in the database exactly (no timezone drift). |
| AC-4.3 | Newest session appears first; a session finished one minute ago outranks one finished an hour ago. |
| AC-4.4 | With no completed sessions, the empty state renders; with one, the empty state disappears and the total updates. |
| AC-4.5 | A back-filled overnight session (FR-3.4 scenario) renders with its planned start and end times, marked completed. |

---

## 7. Data model summary (normative)

```text
focus_sessions
  id                 INTEGER PK AUTOINCREMENT
  label              TEXT NOT NULL
  started_at         DATETIME NOT NULL        -- real timestamp
  ended_at           DATETIME NULL            -- NULL => running
  planned_seconds    INTEGER NOT NULL
  invincible         BOOLEAN DEFAULT false
  blocked_packages   TEXT (JSON list) DEFAULT '[]'
  pause_notifications BOOLEAN DEFAULT true
  block_internet     BOOLEAN DEFAULT false
  block_websites     BOOLEAN DEFAULT false
  completed          BOOLEAN DEFAULT false

app_usage
  id                  INTEGER PK AUTOINCREMENT
  package_name        TEXT NOT NULL
  day                 DATETIME NOT NULL       -- truncated to local midnight
  foreground_seconds  INTEGER DEFAULT 0
  UNIQUE(package_name, day)
```

Durability rules:

- All schedule/expiry logic uses stored timestamps; no in-memory timer is authoritative.
- Deleting all app data (`Settings → Data → Delete all data`) removes all rows from both tables.

---

## 8. Non-functional requirements

| ID | Requirement |
| -- | ----------- |
| NFR-1 | **Reliability:** tracking and history survive process death, app restart, device restart, date rollover, and timezone/DST changes (timestamps stored in UTC-convertible DateTime, displayed local). |
| NFR-2 | **Performance:** app-catalog load must not block first paint of the Limits screen; sorting over a 500-app catalog must complete < 16 ms per frame budget. |
| NFR-3 | **Battery:** no polling loops; re-evaluation happens on DB stream changes and a 15 s cadence tick. |
| NFR-4 | **Privacy:** usage data, session data, and crash logs never leave the device; no account, no cloud, no analytics. |
| NFR-5 | **Consistency:** any value shown on screen (usage, duration, remaining time) must be derived from the same source the enforcement layer consumes. |

---

## 9. Traceability matrix

| Requirement | Implementation | Test coverage |
| ----------- | -------------- | ------------- |
| FR-1 | `NavShell`, root-navigator modals, snackbar margins | Manual QA (AC-1.1 – AC-1.4) |
| FR-2 | `appsCatalogProvider`, `appIconProvider`, `todayUsageByPackageProvider`, Limits screen | Manual QA (AC-2.1 – AC-2.5) |
| FR-3 | `FocusController`, `activeFocusSessionProvider`, `focus_sessions` table, `evaluationTickProvider` | `test/restriction_engine_test.dart` (formatting/engine), manual QA (AC-3.1 – AC-3.5) |
| FR-4 | `focusHistoryProvider`, Focus history tiles, engine formatting utilities | Manual QA (AC-4.1 – AC-4.5) |
