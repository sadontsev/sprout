// Pure source transforms for iOS UIScene adoption. No Expo dependency, so it is unit-testable in
// isolation. Consumed by ./withIosSceneLifecycle.js (the Expo config plugin).
//
// Background: iOS 27 hard-enforces the UIScene life cycle. The Expo SDK 56 template
// AppDelegate.swift creates the window the legacy way (in `didFinishLaunchingWithOptions`), which
// iOS 27 terminates on launch with EXC_BREAKPOINT in
// `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`. We move window creation into a
// SceneDelegate and declare a complete scene manifest.

const UIKIT_IMPORT = 'import UIKit';

// Programmatic complement to the Info.plist manifest. Setting `delegateClass` in code cannot drift
// from a mistyped `UISceneDelegateClassName`, and takes precedence over the plist.
const CONFIG_FOR_CONNECTING = `
  // Added by plugins/withIosSceneLifecycle.js — wires the scene delegate (iOS 27 UIScene life cycle).
  public func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
      name: "Default Configuration",
      sessionRole: connectingSceneSession.role)
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
`;

const SCENE_DELEGATE_CLASS = `
// MARK: - Scene life cycle (required on iOS 27) — added by plugins/withIosSceneLifecycle.js
//
// RN 0.85's \`startReactNative(withModuleName:in:launchOptions:)\` is window-agnostic (it only sets
// \`rootViewController\` + \`makeKeyAndVisible\`), so a scene-owned \`UIWindow(windowScene:)\` works.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
          let appDelegate = UIApplication.shared.delegate as? AppDelegate,
          let factory = appDelegate.reactNativeFactory else {
      return
    }

    // Use the scene-owned initializer (never \`UIWindow(frame:)\`) so safe-area insets and
    // interface orientation resolve correctly.
    let window = UIWindow(windowScene: windowScene)
    self.window = window
    // Keep AppDelegate.window in sync — some RN internals and native libraries still read
    // \`application.delegate.window\`.
    appDelegate.window = window

    factory.startReactNative(
      withModuleName: "main",
      in: window,
      launchOptions: nil)

    // Once a scene delegate exists, iOS routes cold-start URLs through the scene instead of
    // \`application(_:open:options:)\`. Forward them so expo-router deep links keep working.
    if !connectionOptions.urlContexts.isEmpty {
      self.scene(scene, openURLContexts: connectionOptions.urlContexts)
    }
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let urlContext = URLContexts.first,
          let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
      return
    }

    var options: [UIApplication.OpenURLOptionsKey: Any] = [
      .openInPlace: urlContext.options.openInPlace
    ]
    if let sourceApplication = urlContext.options.sourceApplication {
      options[.sourceApplication] = sourceApplication
    }
    if let annotation = urlContext.options.annotation {
      options[.annotation] = annotation
    }

    _ = appDelegate.application(UIApplication.shared, open: urlContext.url, options: options)
  }
}
`;

// Matches the legacy window-creation block in the Expo SDK 56 template AppDelegate.swift.
// Tolerant of whitespace; anchored on the exact statements so a template change is detected.
const LEGACY_WINDOW_BLOCK =
  /#if os\(iOS\) \|\| os\(tvOS\)\s*\n\s*window = UIWindow\(frame: UIScreen\.main\.bounds\)\s*\n\s*factory\.startReactNative\(\s*\n\s*withModuleName: "main",\s*\n\s*in: window,\s*\n\s*launchOptions: launchOptions\)\s*\n\s*#endif\s*?\n/;

// Complete scene manifest. Presence of UISceneConfigurations naming a delegate class is what makes
// iOS treat the app as having adopted the scene life cycle.
const SCENE_MANIFEST = {
  UIApplicationSupportsMultipleScenes: false,
  UISceneConfigurations: {
    UIWindowSceneSessionRoleApplication: [
      {
        UISceneConfigurationName: 'Default Configuration',
        UISceneDelegateClassName: '$(PRODUCT_MODULE_NAME).SceneDelegate',
      },
    ],
  },
};

/**
 * Apply the UIScene adoption transform to AppDelegate.swift source.
 * Pure + idempotent. Throws if the expected template anchors are missing (so a template change is
 * loud rather than producing a silently-crashing app).
 * @param {string} contents
 * @returns {string}
 */
function transformAppDelegate(contents) {
  if (contents.includes('class SceneDelegate')) {
    return contents; // already applied
  }

  if (!LEGACY_WINDOW_BLOCK.test(contents)) {
    throw new Error(
      '[withIosSceneLifecycle] Could not find the legacy window-creation block in AppDelegate.swift. ' +
        'The Expo template changed — update LEGACY_WINDOW_BLOCK before prebuilding, or the app will ' +
        'crash on iOS 27.'
    );
  }
  if (!contents.includes('// Linking API')) {
    throw new Error(
      '[withIosSceneLifecycle] Could not find the "// Linking API" anchor in AppDelegate.swift.'
    );
  }

  // 1) Ensure `import UIKit` (needed for UISceneConfiguration / UIWindowSceneDelegate).
  if (!new RegExp(`^${UIKIT_IMPORT}$`, 'm').test(contents)) {
    contents = contents.replace(
      'import ReactAppDependencyProvider',
      `import ReactAppDependencyProvider\n${UIKIT_IMPORT}`
    );
  }

  // 2) Remove legacy window creation — the SceneDelegate owns the window now.
  contents = contents.replace(
    LEGACY_WINDOW_BLOCK,
    '    // Window + RN root view are created in SceneDelegate (iOS 27 UIScene life cycle).\n'
  );

  // 3) Vend the scene configuration.
  contents = contents.replace('  // Linking API', `${CONFIG_FOR_CONNECTING}\n  // Linking API`);

  // 4) Append the SceneDelegate class.
  contents = `${contents.trimEnd()}\n${SCENE_DELEGATE_CLASS}`;

  return contents;
}

module.exports = { transformAppDelegate, SCENE_MANIFEST, LEGACY_WINDOW_BLOCK };
