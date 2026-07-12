import { isSliced3mf, isPlayableVideo, isTimelapseFolder, timelapseThumbPath, timelapseLabel } from '../printerFiles';

test('isSliced3mf matches .3mf and .gcode.3mf case-insensitively', () => {
  expect(isSliced3mf('Bambu_Cube_XYZ.gcode.3mf')).toBe(true);
  expect(isSliced3mf('model.3MF')).toBe(true);
  expect(isSliced3mf('notes.3mf.txt')).toBe(false);
  expect(isSliced3mf('video.mp4')).toBe(false);
});

test('isPlayableVideo: mp4 only (iOS cannot play the old .avi timelapses)', () => {
  expect(isPlayableVideo('video_2026-07-05_15-16-02.mp4')).toBe(true);
  expect(isPlayableVideo('video.MP4')).toBe(true);
  expect(isPlayableVideo('old.avi')).toBe(false);
});

test('isTimelapseFolder matches only the top-level timelapse dir', () => {
  expect(isTimelapseFolder('/timelapse')).toBe(true);
  expect(isTimelapseFolder('/timelapse/')).toBe(true);
  expect(isTimelapseFolder('/timelapse/thumbnail')).toBe(false);
  expect(isTimelapseFolder('/')).toBe(false);
});

test('timelapseThumbPath maps to the sibling thumbnail jpg (real SD layout)', () => {
  expect(timelapseThumbPath('/timelapse/video_2026-07-05_15-16-02.mp4')).toBe('/timelapse/thumbnail/video_2026-07-05_15-16-02.jpg');
  // no extension -> unchanged (never build a broken URL)
  expect(timelapseThumbPath('/timelapse/weird')).toBe('/timelapse/weird');
});

test('timelapseLabel formats the embedded date, falls back to the raw name', () => {
  expect(timelapseLabel('video_2026-07-05_15-16-02.mp4')).toBe('Jul 5, 15:16');
  expect(timelapseLabel('video_2026-12-31_09-05-59.mp4')).toBe('Dec 31, 09:05');
  expect(timelapseLabel('custom_name.mp4')).toBe('custom_name.mp4');
  expect(timelapseLabel('video_2026-99-05_15-16-02.mp4')).toBe('video_2026-99-05_15-16-02.mp4'); // bogus month
});
