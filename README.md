# PowerTop

**English** | **[简体中文](README.zh-CN.md)**

A clean, lightweight menu bar app that shows you exactly how much power your MacBook is using.

<p align="center">
  <img src="https://img.shields.io/badge/version-1.4.2-blue" />
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" />
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon-green" />
  <img src="https://img.shields.io/badge/license-MIT-orange" />
</p>

> **MacBook only** — Requires a Mac with a built-in battery (Apple Silicon MacBook).

## System resources

The popover also shows CPU/GPU utilization, used/total memory, and upload/download rates. These unprivileged reads use a separate Resource Refresh Interval (default 2 seconds, range 1–300 seconds), independent of the Battery Refresh Interval, so a battery-service error does not stop them. Manual refresh also rereads resources. Monitoring pauses during sleep and resets interval counters on resume.

CPU, GPU, memory and network each have a persisted menu bar toggle, initially enabled. CPU/GPU/MEM use two compact rows (percentage above label); upload/download share a two-row column with decimal K/s and M/s units. All columns occupy one status item, without separate system spacing. Battery and power display remain independent.

CPU is the all-core busy-time fraction between two kernel-counter snapshots. GPU is the driver's `IOAccelerator.PerformanceStatistics["Device Utilization %"]`; unsupported drivers show a dash, and multiple GPUs use the highest reported utilization. Memory is estimated from resident, wired and compressed pages, excluding purgeable/file-backed caches; capacities use GiB. Network speed aggregates 64-bit interface counters using the Lemon selection rules described below. Rates use actual elapsed time, independently clamping non-increasing counters to zero. Network units are decimal B/s, KB/s and MB/s; this is current traffic, not link capacity or an internet speed test. Initial CPU/network rates require two readings; one bootstrap read occurs within one second.

CPU temperature averages the recognized, generation-specific CPU SMC sensors (M1–M5; Intel package sensor when available). The generation-specific key names are cross-checked against the [Stats sensor catalog](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift). Fan speeds are read individually; 0 RPM is valid, no fans and unavailable readings are distinct. The reader only exposes SMC metadata/read commands, never fan control. Menu toggles for temperature, fans and disk start disabled; the fan menu column shows the highest available RPM, while the panel shows each fan.

Startup disk usage reads the writable Data volume and reports decimal GB available/total. Available space prefers macOS important-usage capacity, including reclaimable storage; percentage uses the same available value. APFS sibling volumes are not added together.

Memory Accounting now lives in Menu Bar Layout with a formula explanation. It retains the saved choice and defaults to Subtract reclaimable and file cache. The alternative Active + wired + compressed method uses those three page counts, matching [Tencent Lemon's public `CmcGetPhysMemoryInfo2` implementation](https://github.com/Tencent/lemon-cleaner/blob/master/localPod/LemonStat/LemonStat/Classes/src/CmcMemory.m). Both percentages come from the same VM snapshot and apply consistently to the panel and MEM menu column. They are different definitions, not memory-pressure percentages.

Run `bash scripts/test-hardware-metrics.sh` for SMC decoding, sensor mappings, memory-method and disk-capacity checks; `--read-system` reads actual sensors without administrator authorization.

Run `bash scripts/test-resource-menu.sh` to check all independent menu toggles, persisted intervals, native compact widths and separate scheduling.

Run `bash scripts/test-system-metrics.sh` for counter, rollover, interface-switch, memory and lifecycle tests; add `--read-system` to check real unprivileged readings.

## Menu arrangement and startup items

Menu Bar Layout lets each parameter be moved left/right or reordered by dragging, including battery and power. Order and visibility persist independently; hidden parameters keep their positions. Only the battery and power columns change color with the energy mode. Clicking the status item again or anywhere outside closes the popover; queued positioning updates cannot reopen it.

Startup Items opens a searchable window grouped by application and item type. One expansion shows all child items with type headings. Each app has a master switch for its controllable children and green/blue/gray All Enabled/Partly Enabled/All Disabled badges. Search filters applications without narrowing the master switch. The list refreshes only on opening, explicit Refresh, or verification of a change, independently of battery and resource timers. Each child has its own state, exact source path and Show Original File in Finder action. Classic login applications and eligible user/shared LaunchAgents and `/Library/LaunchDaemons` can be changed individually. Login-app removals retain the app URL and hidden setting for restoration. Enabling a supported launchd service enables automatic startup and immediately bootstraps it if unloaded, then verifies registration. Disabling prevents future automatic startup and immediately boots out a loaded background service, then verifies it is no longer registered. Classic login applications only change their login registration. System-daemon changes and background metadata queries reuse the shared administrator service; individual operations never invoke password prompts.

Bundled services and macOS-controlled background permissions link to System Settings when direct management is not supported. Apple system services are excluded. PowerTop's battery helper remains managed through Administrator Authorization. Duplicate service labels are shown read-only because a label-based override cannot target just one of those files. No startup settings change when opening, searching or refreshing the window. Modern background metadata uses the diagnostic `sfltool dumpbtm` output and reports read failures explicitly; classic login items use the deprecated SharedFileList compatibility API with readback verification.

Run `bash scripts/test-startup-layout.sh` for per-child operations through a mock backend, parser/source validation, order persistence, battery-only pixel color checks and native popover dismissal. `--read-system` additionally inventories real startup items without changing them.

## Energy controls

- Battery percentage and wattage use the same compact two-row numeric/label layout as CPU (BAT/PWR); battery and power display remain independently configurable. The popover re-anchors after the status button moves or resizes. Only the battery and power columns use yellow in Low Power Mode and white in High Power Mode; resource text keeps the normal menu color. While actively charging, a small bolt appears after the battery percentage (or after wattage when battery percentage is hidden). Compact spacing applies within PowerTop only.
- Power readings default to every 2 seconds. Click the interval, enter a value from 1 to 300 seconds, and choose Apply. An Applied indicator appears beside the interval and the control returns to read-only display; Cancel or closing the panel discards unsaved input. Use Refresh Now for an immediate reading. Power-source changes and wake events still refresh immediately.
- Choose Automatic, Low Power, or High Power separately for battery and adapter use, with system readback after each change.
- Administrator Authorization, in the popover settings, enables one shared service for manual/scheduled battery sampling, power-mode switching and startup-item management. It accepts only the installing user's approved app signature. It exposes supported power modes, a fixed non-exclusive battery ReadAll request, startup-state queries, and enable/disable and verified loading/unloading of validated root-owned third-party daemon plists. The helper revalidates paths, labels, ownership, permissions and duplicates, excludes Apple services and itself, and limits returned background records to the installing user and shared records. The app does not run as root, store passwords, modify sudoers, or accept arbitrary commands. This ad-hoc signed build still requires authorization repair after updates/rebuilds.
- Apps Using Significant Energy comes from Control Center's private, read-only `systemstats_get_top_coalitions` query. Defaults were verified on macOS 26.6.2: 120 seconds, top 5, threshold 60000. This is not a CPU ranking or per-app wattage. Different query times may briefly produce different lists; future macOS changes may make it unavailable, in which case the UI reports that explicitly.
- Energy mode settings follow the Battery Refresh Interval, including while the panel is closed. Background reads do not disable mode buttons, and stale reads cannot overwrite a completed mode change. Significant-energy app queries run every 5 seconds only while the panel is open. Long panels scroll to fit the screen.

Authorization and removal feedback appears in the authorization section. The optional root-owned helper lives at `/Library/PrivilegedHelperTools/com.kdolphin.PowerTop.EnergyHelper` with its launchd plist at `/Library/LaunchDaemons/com.kdolphin.PowerTop.EnergyHelper.plist`. Build/test scripts do not install it.

Power values consistently prefer reported watts, then the same component’s current × voltage, then a balance estimate from two independently known components. Battery power prefers `BatteryPower`, then `InstantAmperage × Voltage`, then average `Amperage × Voltage`. Adapter input prefers `SystemPowerIn`, then `SystemCurrentIn × SystemVoltageIn`. System load prefers valid floating-point watts from `BatteryData.SystemPower`, then `PowerTelemetryData.SystemLoad`, and finally an independent power-balance estimate. Both direct readings pass the same consistency checks. A system load exceeding adapter input while the selected battery reading indicates charging is rejected; replacing a contradictory `BatteryPower` with current × voltage must not retain that impossible load. Integer-encoded `BatteryData.SystemPower` values have unspecified units and are not used. Adapter-input voltage/current are never reused as system-load measurements. Valid zeros remain zero, two missing values are not circularly reconstructed, and unavailable values display a dash. The battery node shows its own reading instead of copying the system node. Native battery current and `BatteryPower` are positive while charging and are normalized at the input boundary. The charging header/menu wattage is total adapter input, including battery charging.

Both scheduled refreshes and Refresh Now use the Administrator Service to request a new battery sample, wait up to 10 seconds for UpdateTime to advance, then read the new snapshot. Manual requests join an in-flight sample; timer ticks skip it instead of queuing more work. Sampling pauses during sleep and stops when monitoring stops. Wake/source notifications and interval changes read existing IOKit data without requesting sampling, preventing notification feedback loops. Failed sampling retains cached readings and shows an error on the refresh button. A new timestamp counts as fresh even if wattage is unchanged. Errors and timeouts are explicit; existing data is never presented as a successful new sample.

Active sampling uses a private macOS battery-driver interface and is best-effort; a configured interval is not a guaranteed sensor update rate. Without authorization, cached readings remain available and the refresh button reports the sampling error.

Run `bash scripts/test-active-refresh.sh` to verify scheduled/manual sampling, coalescing, lifecycle cancellation, passive notifications and timestamp/timeout handling with mock sampling. The signed app supports `--configure-admin-service` (administrator authorization, then one real sample) and `--verify-active-refresh` (one real sample through the installed service).

Run `bash scripts/test-power-flow.sh` (optionally `--read-system`) to verify sign handling, real supplement, idle and inconsistent transition samples.

Run `bash scripts/test-energy-modes.sh` (optionally `--read-system`) and `bash scripts/test-integration.sh`. The latter tests signed XPC clients, invalid requests, and actual status-item/popover geometry without installing a daemon or changing energy modes. Administrator installation/removal and actual mode switching require manual verification.

## Finally Know How Much Power You're Using

macOS never tells you the actual watts your MacBook is consuming right now. PowerTop changes that.

It gives you clear, real-time power information directly in the menu bar and a simple popover — so you can see exactly what's happening with power on your machine.

## Key Features

- **Optional menu bar wattage** — Show live power like `23W` right in the menu bar when you want it.
- **Power flow diagram** — See at a glance whether power is coming from the charger, the battery, or both at the same time.
- **Instant power numbers** — System power, charger output, and battery charge or discharge rate.
- **Charger load** — Know your adapter's wattage and how much of it is being used.
- **Battery overview** — Quick view of battery level, health, temperature, and cycle count.
- **Estimated battery time** — Time to empty or full in the popover and detail view; respects macOS charge limits (80/85/90/95%) and third-party apps like AlDente.
- **Detailed information** — Auto-detected cell topology (e.g. 3S2P), series-group voltage, parallel cell currents, charging status, and lifetime stats.

Everything updates live and stays accurate even when you plug in or unplug your charger.

## Why People Use PowerTop

- Curious about real power consumption on their MacBook
- Want to know if their charger is powerful enough during heavy work
- Like seeing when the battery is helping supply power
- Want a simple, beautiful way to monitor battery health and charging behavior

It's a small, native app that does one thing well — no bloat, no subscriptions.

## Installation

### Download (Recommended)

Download the latest `PowerTop.zip` from the [Releases](https://github.com/kDolphin/PowerTop/releases) page:

1. Unzip the file
2. Drag `PowerTop.app` into your `/Applications` folder
3. First launch: right-click the app → **Open** (the app is not signed)

### Build from Source

```bash
git clone https://github.com/kDolphin/PowerTop.git
cd PowerTop
bash build.sh
open build/PowerTop.app
```

## Requirements

- Apple Silicon MacBook (M-series)
- macOS 14 (Sonoma) or later

## How to Use

1. Open PowerTop — the icon appears in your menu bar.
2. Click the icon to open the popover with the power flow diagram and current readings.
3. Turn on **Show Power in Menu Bar** at the bottom if you want the wattage always visible.
4. Click **Details** for a full breakdown of power and battery information.

## Screenshots

### Popover

| **AC Powered** | **Battery Discharging** |
|----------------|--------------------------|
| <a href="screenshot/popover-ac-powered.png" target="_blank"><img src="screenshot/popover-ac-powered.png" width="260" alt="AC Powered"></a> | <a href="screenshot/popover-battery-discharging.png" target="_blank"><img src="screenshot/popover-battery-discharging.png" width="260" alt="Battery Discharging"></a> |

| **AC Charging** | **AC + Battery Supplement** |
|-----------------|------------------------------|
| <a href="screenshot/popover-ac-charging.png" target="_blank"><img src="screenshot/popover-ac-charging.png" width="260" alt="AC Charging"></a> | <a href="screenshot/popover-ac-supplement.png" target="_blank"><img src="screenshot/popover-ac-supplement.png" width="260" alt="AC + Battery Supplement"></a> |

### Detail Window

| **Power & Battery Health** | **Cell Data** |
|----------------------------|---------------|
| <a href="screenshot/detail-window-health.png" target="_blank"><img src="screenshot/detail-window-health.png" width="400" alt="Power and battery health"></a> | <a href="screenshot/detail-window-cells.png" target="_blank"><img src="screenshot/detail-window-cells.png" width="400" alt="Cell topology and balance"></a> |

## What's New

### v1.4.2

- **Popover dismiss** — Clicking outside the panel closes it on macOS 15/26 as well (status-item popovers in menu-bar apps often miss system `.transient` dismiss; issue #13)

### v1.4.1

- **Menu bar label** — Use the native status item title so wattage no longer jumps after the first refresh or stay emphasized when switching displays

### v1.4.0

- **System popover** — Menu bar panel uses a standard `NSPopover` (corners, material, and size follow the system). Fixes background/corner glitches when content height changes.

### v1.3.9

- **Supplement time-to-empty** — When estimating battery time during AC + battery supplement, use pack outflow only, not full system load (thanks @Collinw24, issue #12)

### v1.3.8

- **Manufacture date** — Read explicit `ManufactureDate` from the pack (`YYYY-MM-DD`); stop treating `ManufacturerData` as a week code (thanks @Collinw24, PR #10 / issue #7)

### v1.3.7

- **AC power-gap classification** — When system load exceeds AC input, only treat the battery as discharging if amperage or BatteryPower shows discharge; do not invent supplement power from the load gap alone (reduces false “battery supplement” during telemetry lag; issue #8)

### v1.3.6

- **Manufacture date parsing** — Prefer length-prefixed fields in `ManufacturerData` and reject far-future week codes (avoids bogus dates such as 2035-W14 on some machines; issue #7)

### v1.3.5

- **Popover type consistency** — Battery level and health rows use the same 12pt system font as other metric rows (no shrink-to-fit, no rounded digits)

### v1.3.4

- **Aligned metric bars** — Popover battery level/health rows use a fixed label column and icons so progress bars line up in both Chinese and English
- **Detail window layout** — Shared fixed label/bar columns for overview metrics and key–value rows; window width set to 480pt
- **Cell Data icon** — Uses a broadly available SF Symbol so the section icon is not missing on some macOS versions (thanks @YangFong)

### v1.3.3

- **Charge-limit-aware estimates** — Time-to-full now targets your effective charge limit (macOS Settings, AlDente, or Optimized Charging hold) instead of always assuming 100%
- **Smarter limit detection** — Ignores stale AlDente configs when `useTahoeNativeLimit` is enabled; only uses Optimized Charging `DailyMaxSoc` when the pause flag is active

### v1.3.2

- **Battery health fix** — Reads design capacity, full charge, and health % from `BatteryData` on Apple Silicon; reorganized detail view with aligned overview bars and clearer capacity labels
- **Compact detail window** — Fixed width for a tighter layout

### v1.3.1

- **Adaptive cell topology** — Detects each MacBook's actual S×P layout from IOKit (e.g. 2S2P on Air, 3S2P on Pro); no hardcoded topology

### v1.3.0

- **Estimated battery time** — Computes time to empty or full from remaining energy and smoothed power when macOS stops reporting `AvgTimeToEmpty` / `AvgTimeToFull`; shown in popover and detail view
- **Cell data fix (Apple Silicon)** — Reads per-series-group voltage/Qmax and per-parallel-cell current from IOKit bank/cell nodes; topology is detected per machine
- **Clearer cell balance** — Separate series voltage balance and parallel current balance
- **Detail window polish** — Fixed duplicate rows, moved manufacture date to device info, improved labels

### v1.2.0

- Redesigned detail window, flat layout, instant menu bar updates after wake, 0 W idle fix, cell balance summary

[Older releases →](https://github.com/kDolphin/PowerTop/releases)

## License

MIT License. See [LICENSE](LICENSE) for details.

## On-demand readings

The status item no longer shows a hover data tooltip; its accessibility label remains available. Resource polling follows the visible menu-bar selections while the popover is closed, reads all metrics while it is open, and stops entirely when no resource is displayed. Temperature and fan reads are independent. Disk capacity is cached for 60 seconds (including unavailable results); opening the popover or manually refreshing bypasses the cache. A disk-only menu uses an interval of at least 60 seconds. CPU/network newly enabled counters receive a second sample within one second.

Battery active sampling and configured refresh intervals remain unchanged. Battery serial/model, design cycle count and manufacture date are cached, invalidated when battery identity changes or becomes unavailable. Cell telemetry and lifetime detail parsing occur only while the battery detail window is open; closing or minimizing it stops cell enumeration. Core battery power, charge state and health remain fresh on the existing schedule. The driver still performs its existing ReadAll operation; this optimization reduces app-side work rather than claiming a smaller hardware sampling request.

Run `bash scripts/test-demand-reading.sh` to verify selection-driven polling, idle/slow schedules, cache expiry, detail-window lifecycle and tooltip removal.

Startup service switches follow Lemon: any loaded service is on regardless of its auto-start override; an allowed but unloaded job has an off switch with a Not Loaded label, and unloaded disabled jobs are off without an extra label. Loaded jobs waiting for a trigger still count as loaded. Invalid/unavailable loading-state output is unknown, never disabled. LoginWindow-only jobs cannot be bootstrapped into an Aqua session; an attempted enable reports this limitation without changing their settings. These checks run only with startup-list reads and actions, not battery/resource timers.

Network aggregation follows Tencent Lemon public commit `7ff8676`: sum IFT_ETHER, IFT_PPP, IFT_MODEM and IFT_CELLULAR counters without an up/running filter. Only if cumulative received bytes sum to zero, sum all types except IFT_LOOP, IFT_GIF, IFT_STF and IFT_PKTAP. Divide each direction's positive delta by elapsed time independently; equal or decreased counters yield zero. Existing demand-based scheduling and user refresh intervals are unchanged. Sampling windows may differ from Lemon, so simultaneous UI values need not be identical.

Memory and disk capacity details are available by hovering their percentages in the popover rather than occupying a second text row.

Multi-display status rendering caches both metric values and the resolved appearance color, coalesces duplicate appearance notifications, and materializes 1x/2x bitmap images. This avoids a redraw feedback loop when AppKit mirrors the status item onto external displays.
