const { injectPodMinTarget, MIN_TARGET, RN_POST_INSTALL_CALL } = require('../podfileMinTarget');

// Representative Expo SDK 56 Podfile post_install block (what `expo prebuild` generates).
const PODFILE = `require File.join(...)
platform :ios, podfile_properties['ios.deploymentTarget'] || '16.4'

target 'Bambu' do
  use_expo_modules!

  post_install do |installer|
    react_native_post_install(
      installer,
      config[:reactNativePath],
      :mac_catalyst_enabled => false,
      :ccache_enabled => ccache_enabled?(podfile_properties),
    )
  end
end
`;

describe('injectPodMinTarget', () => {
  const out = injectPodMinTarget(PODFILE);

  it('matches the react_native_post_install anchor in the template', () => {
    expect(PODFILE).toMatch(RN_POST_INSTALL_CALL);
  });

  it('injects a pod-target deployment-target force-bump after react_native_post_install', () => {
    expect(out).toContain('installer.pods_project.targets.each do |target|');
    expect(out).toContain("config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.4'");
    expect(out).toContain(`< ${MIN_TARGET}`);
    // Must land inside the post_install block (before its `end`), after the RN call.
    const rnIdx = out.indexOf('react_native_post_install(');
    const bumpIdx = out.indexOf('installer.pods_project.targets.each');
    expect(rnIdx).toBeGreaterThan(-1);
    expect(bumpIdx).toBeGreaterThan(rnIdx);
  });

  it('is idempotent (re-running does not double-inject)', () => {
    const twice = injectPodMinTarget(out);
    expect(twice).toBe(out);
    expect((twice.match(/installer\.pods_project\.targets\.each/g) || []).length).toBe(1);
  });

  it('honors a custom target', () => {
    const custom = injectPodMinTarget(PODFILE, '17.0');
    expect(custom).toContain("config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'");
    expect(custom).toContain('< 17.0');
  });

  it('throws loudly if the react_native_post_install anchor is missing', () => {
    const changed = PODFILE.replace('react_native_post_install(', 'rn_post_install(');
    expect(() => injectPodMinTarget(changed)).toThrow(/react_native_post_install/);
  });
});
