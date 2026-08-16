// Expo config plugin: force every CocoaPods target to a minimum iOS deployment target.
//
// Companion to expo-build-properties (which sets the app target + Podfile baseline). Needed because
// some pods hardcode a lower podspec deployment_target that Xcode 27 rejects. The source transform
// lives in ./podfileMinTarget.js (pure + unit-tested).

const { withDangerousMod } = require('expo/config-plugins');
const fs = require('fs');
const path = require('path');
const { injectPodMinTarget, MIN_TARGET } = require('./podfileMinTarget');

const withIosPodMinDeploymentTarget = (config, { target = MIN_TARGET } = {}) =>
  withDangerousMod(config, [
    'ios',
    (cfg) => {
      const podfilePath = path.join(cfg.modRequest.platformProjectRoot, 'Podfile');
      const contents = fs.readFileSync(podfilePath, 'utf8');
      fs.writeFileSync(podfilePath, injectPodMinTarget(contents, target));
      return cfg;
    },
  ]);

module.exports = withIosPodMinDeploymentTarget;
