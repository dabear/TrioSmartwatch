# Garmin as a SmartwatchManager plugin: gaps

**Draft for review.** Experimental branch `experimental/garmin-on-smartwatch-manager`. This note looks at what it takes to make Trio's `GarminManager` a `SmartwatchManager` plugin, with `SmartwatchHost` as its delegate, instead of a separate service. The branch is `smartwatch-manager` with the Garmin command series merged in: PR #1680 and its follow-ups, `mountrcg/feat/garmin-command-owner-after-pr1-4`. It builds. Nothing here has run on a Garmin.

## What already fits

- **Data:**
  - glucose, delta (from history), trend and units;
  - IOB and COB;
  - temp and scheduled basal, ISF, eventual glucose and sensitivity ratio (`.therapy`);
  - override and temp target presets.

  These all come from `SmartwatchStatusSnapshot`. Garmin sends no predictions and no alerts.
- **Commands:**
  - `carbs` maps to `requestCarbEntry`;
  - `bolus` maps to `requestBolus`;
  - `activateOverride` / `activateTempTarget` map to `requestOverride` / `requestTempTarget(.activate)`, with the plugin mapping preset names to ids;
  - the cancel commands map to `.cancel`;
  - `status` and `presets` map to `smartwatchManagerRequestsRefresh`.
- **Lifecycle:**
  - devices and app choices are saved in `rawState`;
  - the Connect IQ device-selection callback maps to `watchHostDidReceiveURL`;
  - settings move to the plugin's own settings screen;
  - logging maps to `didLogEvent`.
- **Plugin-internal, unchanged in behaviour:**
  - Garmin's v1 message envelope and its acks, including `partial_failure` for a meal whose bolus failed;
  - its request-ID cache;
  - the command-owner app (PR 5/5);
  - delivery and retries;
  - debouncing, and display formatting.

## Gaps

### Protocol additions

1. **Permissions the plugin can see.** Garmin's watch hides commands the user turned off. Proposal: `SmartwatchStatusSnapshot.permittedActions: SmartwatchCapabilities`, the subset of `effectiveCapabilities` the user allowed. The host still enforces every permission.
2. **Limits outside the bolus context.** The watch needs max carbs (missing) and the bolus step (derivable from `bolusContext.supportedBolusVolumes`, but only with `.remoteBolus`). Proposal: `maximumCarbEntry: Double?` with `.remoteCarbs`.
3. **Request IDs (optional).** Add `requestID: UUID` to each request struct, so a resend after a finished request gets the earlier result back instead of `staleContext`. Garmin's plugin-side cache already does this. A protocol field would make it work across plugin restarts too.
4. **A meal request (optional).** `requestMeal(grams:units:)`, returning a partial result. Without it the plugin adds the carbs and then boluses, waiting for the next snapshot inside the 30 s window.
5. **Smaller ones:**
   - the glucose colour scheme, which is a Trio display setting;
   - the scheduled target, if Garmin keeps showing it rather than the target the algorithm uses;
   - a way for the plugin to ask the host to raise an alert ("Garmin Connect Mobile is missing").

### Host changes (no protocol change)

6. **Revocation and a final check.** Today the Trio host checks permission once and then awaits before `enactBolus`, so a permission turned off in between doesn't stop the bolus. The series bumps a revocation epoch when a switch turns off and re-checks just before the side effect: inside the carb transaction (`storeVerifiedCarbs(authorize:)`), before `enactBolus`, and in `AdjustmentManager`'s `authorize:` paths. The host should do the same. This also closes the gap noted for Loop.
7. **Carbs:**
   - use `storeVerifiedCarbs`, which throws when the save fails, where `storeCarbs` doesn't;
   - date the entry when the user confirmed it, not when the request arrived.
8. **Cancelling with nothing active** should count as success, as in the series, not as `.failed`.
9. **Several plugin slots.** The host holds one watch plugin, so Garmin and Pebble can't run together. Permissions are also global and reset whenever the plugin changes. Garmin as a plugin needs per-plugin slots and permissions.
10. **Migration.** Create the Garmin plugin from the existing Garmin settings and saved devices, and route the `device-select-resp` URL to the host instead of the app special-casing it.

### Decisions for maintainers (safety)

11. **The bolus model.** Garmin lets the user type any amount up to max bolus and max IOB. Our policy also requires a bolus context token and, unless forced, at most the recommendation. The plugin must not make up the token, because that would defeat the check. Options:
    - **(a)** the Garmin watch app shows the recommendation and sends the token back: a watch app change, and the safest option;
    - **(b)** send Garmin boluses as forced, keeping the max bolus, the 15 min interval and the daily limit;
    - **(c)** a host-chosen free-amount mode.
12. **Limits that differ:**

    | | Ours | Garmin series |
    |---|---|---|
    | Request age | 30 s | 2 min |
    | Watch clock ahead | 5 s | 60 s |
    | Between watch boluses | 15 min, plus a daily limit | 6 min hold |
    | Between watch carb entries | 15 min | none |

    Garmin users would see new refusals. Whether 30 s is enough over Garmin Connect Mobile should be measured before anything changes.

## Where each side is stricter

- **Ours:** the request window, the recommendation cap and the token, the bolus and carb intervals, and the daily limit.
- **The series:** revocation with a final check before each side effect, the cached result for a resend, the carb date, and failing when the carb save fails. Items 6–8 bring the host up to it.

## Suggested order

1. Host fixes 6–8. They help Pebble too, and need no protocol change.
2. Protocol additions 1–2.
3. Host change 9, several slots. This has to land before Garmin can run as a plugin.
4. The decision on 11, then the port itself: move `GarminManager`, `GarminMessageRouter` and the Garmin parts of `WatchCommand*` into a plugin, using the delegate instead of Trio services.
5. Additions 3–4 if testing shows resends or meal timing are a problem.

Not medical advice. Any change to bolus limits needs review by maintainers and the people who rely on them.
