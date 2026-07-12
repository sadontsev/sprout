import { isSliced3mf, isPlayableVideo, isMediaFolder, mediaThumbPath, mediaLabel } from '../printerFiles';

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

test('isMediaFolder matches the top-level timelapse AND ipcam dirs only', () => {
  expect(isMediaFolder('/timelapse')).toBe(true);
  expect(isMediaFolder('/timelapse/')).toBe(true);
  expect(isMediaFolder('/ipcam')).toBe(true);
  expect(isMediaFolder('/ipcam/')).toBe(true);
  expect(isMediaFolder('/timelapse/thumbnail')).toBe(false);
  expect(isMediaFolder('/ipcam/thumbnail')).toBe(false);
  expect(isMediaFolder('/')).toBe(false);
});

test('mediaThumbPath maps to the sibling thumbnail jpg (real SD layouts)', () => {
  expect(mediaThumbPath('/timelapse/video_2026-07-05_15-16-02.mp4')).toBe('/timelapse/thumbnail/video_2026-07-05_15-16-02.jpg');
  // ipcam basenames contain DOTS (".<seq>.mp4") — only the final extension is swapped.
  expect(mediaThumbPath('/ipcam/ipcam-record.2026-04-21_22-12-16.0.mp4')).toBe('/ipcam/thumbnail/ipcam-record.2026-04-21_22-12-16.0.jpg');
  // no extension -> unchanged (never build a broken URL)
  expect(mediaThumbPath('/timelapse/weird')).toBe('/timelapse/weird');
});

test('mediaLabel formats the embedded date, falls back to the raw name', () => {
  expect(mediaLabel('video_2026-07-05_15-16-02.mp4')).toBe('Jul 5, 15:16');
  expect(mediaLabel('ipcam-record.2026-04-21_22-12-16.0.mp4')).toBe('Apr 21, 22:12');
  expect(mediaLabel('video_2026-12-31_09-05-59.mp4')).toBe('Dec 31, 09:05');
  expect(mediaLabel('custom_name.mp4')).toBe('custom_name.mp4');
  expect(mediaLabel('video_2026-99-05_15-16-02.mp4')).toBe('video_2026-99-05_15-16-02.mp4'); // bogus month
});
