# Wattline

A menu bar app that explains your Mac's battery: what each app costs you in battery time, right now.

- **Build:** `./build.sh` (arm64, signed with a local identity) · **Installer:** `./package.sh` → `dist/` (universal .pkg, .dmg, .zip + How to Install.txt)
- **Requires** macOS 14+. Charge limit needs Apple silicon + macOS 26.4+.

## How it works
| What | Source |
|---|---|
| Per-app power | `proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj` (kernel energy counters); CPU-time estimate (≈) for processes without energy |
| GPU share | `IOAccelerator` user clients' `accumulatedGPUTime` per process |
| Battery, charger | `AppleSmartBattery` registry (`PowerTelemetryData.SystemLoad`, `AdapterDetails`, `BatteryData`) + push notifications from `IOPSNotificationCreateRunLoopSource` |
| Temperature | SMC keys `TB0T/TB1T/TB2T` (read-only) |
| Charge limit | macOS's own setting through PowerUI's `PowerUISmartChargeClient` (runtime-checked) |
| Low Power Mode | `pmset -a lowpowermode`, via a two-command sudoers rule the .pkg installs |
| Accessories | `system_profiler SPBluetoothDataType` + HID `BatteryPercent`, refreshed on Core Audio / IORegistry change events |
| Time cost | `T × Papp / (Psystem − Papp)` |

Sampling: every 2 s while the panel is open, every 5 min otherwise (apps measured only on battery). History is hourly summaries in `~/Library/Application Support/Wattline/history.json`.

Extras: per-app battery budgets, automatic Low Power Mode, a "Why It's Warm" view (temperature next to the busiest app), screen-brightness savings, sleep-wake causes (`kern.wakereason` per wake; `pmset -g log` on request), a wear forecast, calendar-aware charging, a WidgetKit extension (`Sources/WattlineWidget`, reads `widget.json`), and Shortcuts support via `wattline://` URLs and `--time-left` / `--status` / `--charge-limit N` / `--quit-hungriest`.

Test flags: `--dump` (prints per-app watts), `--snapshot <dir>`, `--open-panel [secs] --capture <png>`.
