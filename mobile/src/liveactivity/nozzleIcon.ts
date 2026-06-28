// Brand nozzle glyph for the Live Activity. The widget extension is a separate process and can only
// load a local image (Image `uiImage`) from the shared App Group container. So the app writes this
// PNG (rendered from nozzle-glyph.svg) into expo-widgets' App Group dir at startup, and passes the
// resulting file:// URI to the activity. `uiImage` can't be re-tinted, so this is the fixed brand
// mark (teal bead = the signature); print state is conveyed by the label / % / progress colour.
import { Platform } from 'react-native';
import { widgetsDirectory } from 'expo-widgets';
import * as FileSystem from 'expo-file-system/legacy';

const NOZZLE_PNG_B64 =
  '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EF2BBUhRT0/PGKBP1np/gfy0q6trNMlMdDkWIGWlIP4JgOEa7jqiJXli7s2oHixAyu5eu/YcgF9Vez8Fnu7uXvl+CpFoGhYgA1LQHQCiOTecEkPCH6eVh6awABlYv2bNSQX2Vbq9QP+wofOu42lmokksQEZEdXul20ZxyA++MsICZKS7a83fADlYwaYvf+6zK3tTD0QAWIBMSSVLGrjsIVNcCpGhqy2PmIHLHjLGV4AMiUiswOOzbMJlDxljATI2y/IILnswwAJk7FrLI7jswQYLYOAqyyO47MEIC2Bg5vIILnuwwwIYmbY8gsseyKeXevt+d6D30B7rHJ7xijBLGu/gOU9bPj8IUw3aju5/AKpbAayC4BYokv8+wzwTRFAMAugDsHOgbcNv4fAzCHcFaO8/sDQOomcA3GWdJU9E8XfRcPORO9eftM6SJVcFaO8/sDQOo1eg+Kh1lpwaDCPp7O/YcMo6SFb8nAVSDeIgeoYH/6xuiQrYDVU3x4WbP7Tt6P4HwLFnbqqr2gb+ssU6RlbcFADAg9YB5g/Zap0gK34KoLrKOsI8sto6QFb8FAC40TrAPHKTdYCseCrAOesA84bgrHWErHgqQJ91gPlCYhyyzpAVTwXYaR1g/pj61fv/d34+CFMNVrz20iEVrLSOknN9A20b1npZFuHnFUAkFg03Axi0jpJjg1Gom70c/ICnAgA4cuf6k2EknRB51TpLDvWFkXQeW95z2jpIlvyMQNOpBpOfdspWAKsh+JjT1aDvAXJIFDtfW9G929MzPxEREREREREREREREREREREREREREREREREREREREREREREREREREVEO/A8fesVw+GgB4AAAAABJRU5ErkJggg==';

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
