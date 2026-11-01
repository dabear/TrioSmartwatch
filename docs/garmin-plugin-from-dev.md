# Garmin as a SmartwatchManager plugin, from Trio dev's GarminManager

**Experimental.** Branch `experimental/garmin-plugin-from-dev`, off `smartwatch-manager`.

The earlier attempt (`experimental/garmin-on-smartwatch-manager`) started from the #1680 command series: a command pipeline with boluses, carbs and presets from the watch, Garmin's own looser limits, about 6,300 changed lines, some of the series' tests failing, never run on a Garmin. This attempt starts from Trio `dev`'s `GarminManager` instead, which only shows data: nothing goes from the watch to Trio.

## Approach

- One class, `GarminSmartwatchManager` (dev's `BaseGarminManager`, renamed): a `SmartwatchManager` plugin in the host's watch slot. It declares glucose, history, loop status and therapy, and **no remote actions**.
- It keeps everything Connect IQ from dev: devices, watch apps, settings, throttling, debouncing, sending. Only its data source changes: it builds the Garmin watch state from the host's latest snapshot instead of reading Core Data, files and services itself.
- The host creates it like any watch plugin; there is no separate Garmin service. It gets Trio's services through a resolver the host sets. Garmin Connect's device-selection callback reaches it through the host (`watchHostDidReceiveURL`).
- Without the plugin added, Garmin gets no data; Trio's Garmin settings say so.

## Differences from dev, all from the host's snapshot

- **Temp basal:** the pump's live temp basal (dev sent the last temp basal event without checking its expiry), else the scheduled basal from the determination.
- **Loop time:** Trio's last loop date, rather than the last enacted determination; still 31 minutes ago when there is none.
- **Target:** the target the algorithm used, which includes overrides and temp targets; dev sent the scheduled profile target.
- **Updates:** each new snapshot (sent when a reading or the loop result changes) rather than dev's own Core Data timers.

## Steps

1. [x] This plan.
2. [x] Garmin watch state built from a snapshot, as a pure function with tests (`GarminWatchState+Snapshot.swift`, 7 tests).
3. [x] `BaseGarminManager` reads snapshots instead of Core Data, files and services (450 lines fewer; the Connect IQ code is unchanged).
4. [x] `GarminSmartwatchManager` plugin, listed in the host's plugins (Add Watch → Garmin). Its settings explain it and remove it.
5. [x] Build and tests: Trio builds; the Garmin snapshot, host and container tests pass (13).
6. [x] Trio's Garmin settings say, while the plugin isn't added, that Garmin gets no data until it is.
7. [x] One class: `BaseGarminManager` merged into `GarminSmartwatchManager`; no `GarminManager` service or protocol. Removing the plugin unregisters it from Connect IQ.

## Left after these steps

- Not run on a device or a Garmin yet; only simulator builds and unit tests.

- The host holds one watch plugin: Garmin and Pebble can't run at the same time.
- Garmin's devices and settings stay in Trio's Garmin settings (devices under dev's key), not in the plugin's `rawState`.
- The glucose colour scheme and the display choices are still read from Trio's settings.
- Test on a Garmin.
