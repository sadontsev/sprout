/** A REAL cooldown, recorded from the printer: bed temperature once per minute from the moment the
 *  print finished (69°C) until it settled at 33°C, 89 minutes later. It crossed 35°C at minute 72.
 *
 *  Kept as a fixture because synthetic curves flattered two earlier versions of this module that
 *  were badly wrong against real data — the readings are quantized to whole degrees, and the decay
 *  is not a single exponential. Room temperature at the time was ~28.5°C (office sensor).
 */
export const REAL_COOLDOWN_C: number[] = [
  69, 67, 65, 64, 63, 61, 60, 59, 58, 57, 56, 56, 55, 54, 53, 53,
  52, 51, 51, 50, 50, 49, 48, 48, 48, 47, 47, 46, 46, 45, 45, 45,
  44, 44, 44, 43, 43, 43, 42, 42, 42, 41, 41, 41, 41, 40, 40, 40,
  40, 39, 39, 39, 39, 39, 38, 38, 38, 38, 38, 37, 37, 37, 37, 37,
  37, 36, 36, 36, 36, 36, 36, 36, 35, 35, 35, 35, 35, 35, 35, 35,
  35, 34, 34, 34, 34, 34, 34, 33, 33, 33,
];

/** Minute at which the real curve crossed the default 35°C threshold. */
export const REAL_READY_MIN = 72;
/** Room temperature during that cooldown, from an independent sensor. */
export const REAL_AMBIENT_C = 28.5;
