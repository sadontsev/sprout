// Brand nozzle glyph for the Live Activity. The widget extension is a separate process and can only
// load a local image (Image `uiImage`) from the shared App Group container. So the app writes this
// PNG (rendered from nozzle-glyph.svg) into expo-widgets' App Group dir at startup, and passes the
// resulting file:// URI to the activity. `uiImage` can't be re-tinted, so this is the fixed brand
// mark (teal bead = the signature); print state is conveyed by the label / % / progress colour.
import { Platform } from 'react-native';
import { widgetsDirectory } from 'expo-widgets';
import * as FileSystem from 'expo-file-system/legacy';

const NOZZLE_PNG_B64 =
  'iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAYAAADimHc4AAAABmJLR0QA/wD/AP+gvaeTAAAEh0lEQVR4nO3cz2scZRgH8O8zM83uGvFmcigiqNFUK5YYmrhodMGj4FmlxYv26H/gTU+htopSI9iaWq2KBQ/eCmq0rCYpLdiE1G1BqQoxKFRtd/bHvI+H/DDZZpOmmeb7jj6f42bZ5+H97jwz7+wQwBhjjDHGGGOMMcYYY4wxxpj/MmE3UKlUcrFG+0T1WQA7AXTe5JJXAJwTwbEOSUZ6enpqN7nemqgBnD1/aXuExucAHmK10MS2p3bdd8cvpPq8ACqVSq7mwu/AW/xFZ3NBMsg6EgJGUQCINdoH/uIDwK66C19gFacFIKrPsWq3cgCtF1oAAO4n1l5B5k/+FMwAbiXWbkXrhRmAgQVAZwGQWQBkFgCZBUBmAZBZAGQWAJkFQGYBkFkAZMwA/ibWbvUnqzAzgGli7RWU2AvvBxnB+6zarQLgGKt2xCo8Pn5mItom1Wo1LrB6AIBbCvlqveYmWPVpR0AjqR1iLz4AXK3GhabW32bV550DFHfSarci9kI8CethXu0WindZpWnPBamqjBz58OlA0K8qlHORiDadYvLF55/5TESU0YMhoz8bupqx8uQU0n5sRTE1VOynPX7Sjpe3IhT6SdqfKSKpf2YavAzAqRxP+zPVArh+pWL/DNK8PaCYGhrs8+bWx3JeBgCkO4Z8HT+AxwGkOYZ8HT+AxwGkNoY8Hj+AxwEA6Ywhn8cP4HkA7cZQAmAmTHCyo4GTHQ3MhAlcm8/wefwAnm7ElmvdlF0IE4zma5gLVi55lwuwJ87hniT890VPN1/LeX0EACvH0IUwwcFCfM3iA8BvgcPBQoyLYbL0mu/jB8hAAItjKAEwmq+hucY9s6YojubjpXHk+/gBMhDA4tVQJUxW/ea3mg0UP0RN769+FnkfADA/hi4tGy3r+TnQTIwfICMBOJXjssHrhSyMHyAjAZSK/TNdTn663vd3q/yYhfEDZCQAAOhtBKNdbv12u12AHfVodAtaSkVmAggRfLAnziHS9qMoUsHeOI8oCD7awtY2xfuN2HJj5dOnLobN4tF8jNlg5eVotwuwN87jriQ4NfRI/6OkFjeM9mDWjRDF8N1JeOLlK504HyX4deGydLsT3NuM5g9nxTC1yQ3K1BGgqsE3356eUqC3zVsqjw0+3Csi628YPJGZcwAAiIhT4PU13rI/S4sPZCwAAEjivw4rMLvKn+Yirb+35Q1tUuYCKJVKMaCHWl8XyJvFYrHK6GkzMhcAADQC9wbm//fboqvakLdY/WxGJgN4cmDgdwBLmy0FjgwN9c0RW7phmQwAACTSYczfpXaQ8AC7n/+lr8qTJ74uT3zK7mMzMrURu4a64Uxdc66CthHbMT3WFzh3AMBuADlSGzUA4yry0vQDj59hNEAJYGHxywA6GPVXUVeRQUYIlJPwwjffl8UHgA4BXmMUZl0F7SbVbU91gFGWFcAfpLprofTECuAdUt22VGSEUZcTgNz+igDe/Giuio8L1c5XGbWpvwfs/P6LJwApquhtjPoqcjlwWj73YOlLRn1jjDHGGGOMMcYYY8wW+gc+BWDvC9yidQAAAABJRU5ErkJggg==';

let writeStarted = false;

/**
 * Returns the file:// URI of the brand-nozzle glyph in the App Group container (so the widget can
 * load it), writing the PNG there once. Returns '' when unavailable (non-iOS / Expo Go stub).
 */
export function nozzleIconUri(): string {
  if (Platform.OS !== 'ios') return '';
  const dir = widgetsDirectory; // "file:///.../ExpoWidgets/" — App Group container; '' on the stub
  if (!dir) return '';
  const uri = dir.endsWith('/') ? `${dir}nozzle.png` : `${dir}/nozzle.png`;
  if (!writeStarted) {
    writeStarted = true;
    FileSystem.writeAsStringAsync(uri, NOZZLE_PNG_B64, { encoding: FileSystem.EncodingType.Base64 }).catch(() => {
      writeStarted = false; // allow a retry on the next call
    });
  }
  return uri;
}
