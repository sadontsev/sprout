const {
  transformAppDelegate,
  SCENE_MANIFEST,
  LEGACY_WINDOW_BLOCK,
} = require('../iosSceneTransform');

// Pristine Expo SDK 56 template AppDelegate.swift (what `expo prebuild` regenerates).
const TEMPLATE = `internal import Expo
import React
import ReactAppDependencyProvider

@main
class AppDelegate: ExpoAppDelegate {
  var window: UIWindow?

  var reactNativeDelegate: ExpoReactNativeFactoryDelegate?
  var reactNativeFactory: RCTReactNativeFactory?

  public override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let delegate = ReactNativeDelegate()
    let factory = ExpoReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()

    reactNativeDelegate = delegate
    reactNativeFactory = factory

#if os(iOS) || os(tvOS)
    window = UIWindow(frame: UIScreen.main.bounds)
    factory.startReactNative(
      withModuleName: "main",
      in: window,
      launchOptions: launchOptions)
#endif

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Linking API
  public override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options) || RCTLinkingManager.application(app, open: url, options: options)
  }

  // Universal Links
  public override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    let result = RCTLinkingManager.application(application, continue: userActivity, restorationHandler: restorationHandler)
    return super.application(application, continue: userActivity, restorationHandler: restorationHandler) || result
  }
}

class ReactNativeDelegate: ExpoReactNativeFactoryDelegate {
  // Extension point for config-plugins

  override func sourceURL(for bridge: RCTBridge) -> URL? {
    // needed to return the correct URL for expo-dev-client.
    bridge.bundleURL ?? bundleURL()
  }

  override func bundleURL() -> URL? {
#if DEBUG
    return RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: ".expo/.virtual-metro-entry")
#else
    return Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}
`;

describe('transformAppDelegate', () => {
  const out = transformAppDelegate(TEMPLATE);

  it('removes the legacy window-creation block', () => {
    expect(TEMPLATE).toMatch(LEGACY_WINDOW_BLOCK);
    expect(out).not.toContain('UIWindow(frame: UIScreen.main.bounds)');
    // The legacy block started RN from didFinishLaunching; that must be gone.
    expect(out).not.toContain('in: window,\n      launchOptions: launchOptions)');
  });

  it('adds the UIKit import exactly once', () => {
    const matches = out.match(/^import UIKit$/gm) || [];
    expect(matches).toHaveLength(1);
  });

  it('vends a UISceneConfiguration pointing at SceneDelegate', () => {
    expect(out).toContain('configurationForConnecting connectingSceneSession: UISceneSession');
    expect(out).toContain('configuration.delegateClass = SceneDelegate.self');
    // The config name must match the Info.plist manifest entry.
    expect(out).toContain('name: "Default Configuration"');
  });

  it('appends a SceneDelegate that owns the window and starts React Native', () => {
    expect(out).toContain('class SceneDelegate: UIResponder, UIWindowSceneDelegate');
    expect(out).toContain('let window = UIWindow(windowScene: windowScene)');
    expect(out).toContain('factory.startReactNative(');
    expect(out).toContain('appDelegate.window = window');
  });

  it('preserves the original Linking API and Universal Links handlers', () => {
    expect(out).toContain('open url: URL,');
    expect(out).toContain('continue userActivity: NSUserActivity,');
    expect(out).toContain('RCTLinkingManager.application');
  });

  it('is idempotent (re-running does not double-apply)', () => {
    const twice = transformAppDelegate(out);
    expect(twice).toBe(out);
    expect((twice.match(/class SceneDelegate/g) || []).length).toBe(1);
    expect((twice.match(/configurationForConnecting/g) || []).length).toBe(1);
  });

  it('throws loudly if the window block anchor is missing (template changed)', () => {
    const changed = TEMPLATE.replace('window = UIWindow(frame: UIScreen.main.bounds)', 'window = makeWindow()');
    expect(() => transformAppDelegate(changed)).toThrow(/window-creation block/);
  });

  it('throws if the "// Linking API" anchor is missing', () => {
    const noAnchor = TEMPLATE.replace('  // Linking API\n', '');
    expect(() => transformAppDelegate(noAnchor)).toThrow(/Linking API/);
  });
});

describe('SCENE_MANIFEST', () => {
  it('declares a single non-multiscene window-application config naming the SceneDelegate', () => {
    expect(SCENE_MANIFEST.UIApplicationSupportsMultipleScenes).toBe(false);
    const roles = SCENE_MANIFEST.UISceneConfigurations.UIWindowSceneSessionRoleApplication;
    expect(roles).toHaveLength(1);
    expect(roles[0].UISceneDelegateClassName).toBe('$(PRODUCT_MODULE_NAME).SceneDelegate');
    expect(roles[0].UISceneConfigurationName).toBe('Default Configuration');
  });
});
