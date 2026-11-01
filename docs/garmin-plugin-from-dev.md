# Garmin as a SmartwatchManager plugin, from Trio dev's GarminManager

**Experimental.** Branch `experimental/garmin-plugin-from-dev`, off `smartwatch-manager`.

The earlier attempt (`experimental/garmin-on-smartwatch-manager`) started from the #1680 command series: a command pipeline with boluses, carbs and presets from the watch, Garmin's own looser limits, about 6,300 changed lines, some of the series' tests failing, never run on a Garmin. This attempt starts from Trio `dev`'s `GarminManager` instead, which only shows data: nothing goes from the watch to Trio.

## Approach

- `GarminSmartwatchManager` is a `SmartwatchManager` plugin in the host's watch slot. It declares glucose, history, loop status and therapy, and **no remote actions**.
- `BaseGarminManager` keeps everything Connect IQ: devices, watch apps, settings, throttling, debouncing, sending. Only its data source changes: it builds the Garmin watch state from the plugin's latest snapshot instead of reading Core Data, files and services itself.
- Without the plugin added, Garmin gets no data.

## Differences from dev, all from the host's snapshot

- **Temp basal:** the pump's live temp basal (dev sent the last temp basal event without checking its expiry), else the scheduled basal from the determination.
- **Loop time:** Trio's last loop date, rather than the last enacted determination; still 31 minutes ago when there is none.
- **Target:** the target the algorithm used, which includes overrides and temp targets; dev sent the scheduled profile target.
- **Updates:** each new snapshot (sent when a reading or the loop result changes) rather than dev's own Core Data timers.

## Steps

1. [x] This plan.
2. [x] Garmin watch state built from a snapshot, as a pure function with tests (`GarminWatchState+Snapshot.swift`, 7 tests).
3. [ ] `BaseGarminManager` reads snapshots instead of Core Data, files and services.
4. [ ] `GarminSmartwatchManager` plugin, listed in the host's plugins.
5. [ ] Build and tests.

## Left after these steps

- The host holds one watch plugin: Garmin and Pebble can't run at the same time.
- Garmin's devices and settings stay in Trio's Garmin settings, not in the plugin's `rawState`; the device-selection URL still goes to `BaseGarminManager` directly.
- The glucose colour scheme and the display choices are still read from Trio's settings.
- Test on a Garmin.
