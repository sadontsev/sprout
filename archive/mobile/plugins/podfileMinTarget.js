// Pure Podfile transform: force every CocoaPods target to a minimum iOS deployment target.
// No Expo dependency, so it is unit-testable in isolation. Consumed by
// ./withIosPodMinDeploymentTarget.js (the Expo config plugin).
//
// Why this is needed on top of expo-build-properties: `ios.deploymentTarget` sets the Podfile
// `platform :ios` baseline and the app target, but some pods (e.g. RNSVG-RNSVGFilters) hardcode a
// lower `deployment_target` in their podspec, which CocoaPods honors. Xcode 27 then fails the build
// ("deployment target 12.4 ... supported range is 15.0 to 27.0"). This injects a post_install loop
// that overrides every pod target below the minimum — matching the proven manual fix, but durable
// across `expo prebuild`. Keep MIN_TARGET in sync with app.json's expo-build-properties
// ios.deploymentTarget.

const MIN_TARGET = '16.4';

const MARKER = 'withIosPodMinDeploymentTarget';

// Anchored on the react_native_post_install(...) call so injection lands inside the post_install
// block; throws if the Expo Podfile template changes rather than silently no-op'ing.
const RN_POST_INSTALL_CALL = /react_native_post_install\([\s\S]*?\n {4}\)\n/;

function bumpSnippet(target) {
  return `
    # Added by plugins/${MARKER}.js — Xcode 27 rejects pods below iOS 15.0. Some pods hardcode a
    # lower deployment target in their podspec, which the Podfile \`platform :ios\` baseline does not
    # override. Force every pod target up to the app minimum.
    installer.pods_project.targets.each do |target|
      target.build_configurations.each do |config|
        if (config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] || '0').to_f < ${target}
          config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '${target}'
        end
      end
    end
`;
}

/**
 * Inject the pod deployment-target force-bump into a Podfile's post_install block.
 * Pure + idempotent. Throws if the expected react_native_post_install anchor is missing.
 * @param {string} podfile
 * @param {string} [target]
 * @returns {string}
 */
function injectPodMinTarget(podfile, target = MIN_TARGET) {
  if (podfile.includes(MARKER)) {
    return podfile; // already applied
  }
  if (!RN_POST_INSTALL_CALL.test(podfile)) {
    throw new Error(
      `[${MARKER}] Could not find the react_native_post_install(...) call in the Podfile. ` +
        'The Expo template changed — update RN_POST_INSTALL_CALL, or pods below iOS 15.0 will fail ' +
        'the Xcode 27 build.'
    );
  }
  return podfile.replace(RN_POST_INSTALL_CALL, (match) => match + bumpSnippet(target));
}

module.exports = { injectPodMinTarget, MIN_TARGET, RN_POST_INSTALL_CALL };
