/** Pure helpers for the printer SD-card browser (unit-tested; no React). */

/** Sliced Bambu print files (.gcode.3mf / .3mf) — get plate preview + the layer viewer. */
export const isSliced3mf = (name: string): boolean => /\.3mf$/i.test(name);

/** iOS AVPlayer plays the printer's timelapse .mp4s; .avi (older firmwares) is NOT playable. */
export const isPlayableVideo = (name: string): boolean => /\.mp4$/i.test(name);

/** The printer's timelapse folder ("/timelapse") — rendered as a thumbnail grid, not rows. */
export const isTimelapseFolder = (path: string): boolean => /^\/timelapse\/?$/i.test(path);

/** The printer stores a poster JPEG per video with the SAME basename in a `thumbnail` subfolder:
 *  /timelapse/video_x.mp4 -> /timelapse/thumbnail/video_x.jpg (verified on the live H2C SD card). */
export function timelapseThumbPath(videoPath: string): string {
  const m = videoPath.match(/^(.*)\/([^/]+)\.[^./]+$/);
  return m ? `${m[1]}/thumbnail/${m[2]}.jpg` : videoPath;
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "video_2026-07-05_15-16-02.mp4" -> "Jul 5, 15:16" (falls back to the raw name). */
export function timelapseLabel(name: string): string {
  const m = name.match(/(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})/);
  if (!m) return name;
  const month = MONTHS[Number(m[2]) - 1];
  return month ? `${month} ${Number(m[3])}, ${m[4]}:${m[5]}` : name;
}
