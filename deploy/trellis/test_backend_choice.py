"""Which push backend a deployment ends up with, and why.

Pure re-implementation of the selection in app.py's config block. It lives here rather than being
imported because that block runs at MODULE IMPORT and calls SystemExit — importing it under a
matrix of environments would take the test process down with it.

Keeping a copy honest is the risk, so the test that matters most is
test_matches_the_module_constant, which reads the real app.py and fails if the default drifts.
"""

import pathlib
import re
import unittest


class TheRelayIsTheOnlyBackend(unittest.TestCase):
    """Trellis holds no Apple credentials and has no second way to push.

    It once chose between relaying and signing locally with its own .p8. That mode is gone: anyone
    wanting their own push service runs their own Canopy, which is where the credentials belong.
    Every bug the choice produced came from two backends having to agree — a JWT signed with an
    empty issuer, a compose guard drifting out of step with the code, two files disagreeing about
    the default APNs host, a key mount naming a path that did not exist.
    """

    def setUp(self):
        import pathlib as _p
        self.app = (_p.Path(__file__).parent / "app.py").read_text()
        self.compose = (_p.Path(__file__).parent / "docker-compose.yml").read_text()
        self.example = (_p.Path(__file__).parent / ".env.example").read_text()
        self.reqs = (_p.Path(__file__).parent / "requirements.txt").read_text()

    def test_no_apns_configuration_survives(self):
        for name in ("APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "APNS_HOST",
                     "APNS_KEY_PATH", "APNS_BUNDLE_ID"):
            self.assertNotIn(name, self.app, f"{name} is Canopy's business, not Trellis's")
            self.assertNotIn(name, self.compose)
            self.assertNotIn(name, self.example)

    def test_nothing_signs_a_push_here(self):
        # The JWT minter and its dependency both go with the mode.
        self.assertNotIn("import jwt", self.app)
        self.assertNotIn("_apns_token", self.app)
        self.assertNotIn("pyjwt", self.reqs.lower())

    def test_there_is_no_mode_to_be_in(self):
        self.assertNotIn("RELAY_MODE", self.app,
                         "a flag with one possible value is a branch nobody can test")

    def test_the_relay_defaults_and_is_overridable(self):
        self.assertIn('CANOPY_URL = os.environ.get("CANOPY_URL", "").rstrip("/") or DEFAULT_CANOPY_URL',
                      self.app)


class SelfHostingGuideExists(unittest.TestCase):
    """The other half of the requirement: a default for most people, instructions for the rest."""

    def setUp(self):
        self.guide = pathlib.Path(__file__).parents[2] / "docs" / "guides" / "self-hosting-push.md"

    def test_the_guide_is_present(self):
        self.assertTrue(self.guide.exists(), "app.py and compose both point readers at this file")

    def test_it_states_the_constraint_that_makes_self_hosting_pointless_otherwise(self):
        # APNs keys are team-scoped and the topic is the bundle id, so self-hosting Canopy without
        # also building the app yourself yields a relay that authenticates you and then cannot
        # deliver anything. Someone who misses this loses an evening.
        # Emphasis stripped: the sentence carries markdown bold in the middle of the phrase, and a
        # literal substring match on the raw text would break on a purely cosmetic edit.
        text = self.guide.read_text().lower().replace("*", "")

        self.assertIn("your own build of the app", text)
        self.assertIn("bundle id", text)
        self.assertIn("team-scoped", text, "the reason must be stated, not just the rule")


class TheExampleEnvMatchesTheDefault(unittest.TestCase):
    """.env.example is the first thing a new deployment copies, so it IS the setup instructions.

    It shipped `APNS_KEY_ID=` / `APNS_TEAM_ID=` / `APNS_TOPIC=...` uncommented, under a header
    saying the deploy "fails loudly if the APNS_* values are missing" — written when signing locally
    was the only mode. Following it means obtaining an Apple developer account to do something that
    now requires none, and it contradicts the README's "BAMBUDDY_API_KEY is the only value you must
    set". Documentation that disagrees with the code sends people to fix the wrong thing.
    """

    def setUp(self):
        import pathlib
        self.path = pathlib.Path(__file__).parent / ".env.example"
        self.active = [
            line.split("=", 1)[0]
            for line in self.path.read_text().splitlines()
            if line.strip() and not line.strip().startswith("#") and "=" in line
        ]

    def test_only_the_bambuddy_key_is_uncommented(self):
        self.assertEqual(
            self.active, ["BAMBUDDY_API_KEY"],
            "everything else is for self-hosting and must stay commented, or a new deployment is "
            "told to configure Apple credentials the default path does not use",
        )

    def test_it_says_what_happens_with_nothing_set(self):
        text = self.path.read_text().lower()
        self.assertIn("relays through the push service", text)
        self.assertIn("recovery code", text,
                      "printed once at enrolment and never served from an endpoint; a deployment "
                      "that misses it cannot re-adopt its bindings after losing the data volume")

    def test_it_points_at_the_self_hosting_guide(self):
        self.assertIn("docs/guides/self-hosting-push.md", self.path.read_text())


class TheRequiredCredentialIsActuallyRequired(unittest.TestCase):
    """Present-but-empty and absent are the same thing for a credential.

    compose turns an unset variable into the EMPTY STRING, so `os.environ["BAMBUDDY_API_KEY"]`
    never raised: Trellis booted with a blank key and every Bambuddy call answered 401. That reads
    as "Bambuddy is broken" and sends the operator to the wrong service entirely.

    The inversion is what made it worth fixing: six OPTIONAL push variables carried a comment
    claiming the deploy fails loudly without them, while the one genuinely required value failed
    silently.
    """

    def setUp(self):
        import pathlib
        self.compose = (pathlib.Path(__file__).parent / "docker-compose.yml").read_text()
        self.app = (pathlib.Path(__file__).parent / "app.py").read_text()

    def test_compose_fails_the_deploy_without_it(self):
        self.assertIn("BAMBUDDY_API_KEY: ${BAMBUDDY_API_KEY:?", self.compose,
                      "a bare ${VAR} interpolates to empty, which is not the same as required")

    def test_the_module_rejects_an_empty_key(self):
        # For anyone running it outside compose, where nothing sets the variable at all.
        self.assertIn('os.environ.get("BAMBUDDY_API_KEY", "").strip()', self.app)
        self.assertIn("BAMBUDDY_API_KEY is empty", self.app)

    def test_compose_restates_no_default_that_app_py_already_has(self):
        """A line in compose that duplicates the code's default is a second place to be wrong.

        BAMBUDDY_URL, APNS_KEY_PATH, DATA_DIR and BAMBUDDY_DB were all byte-identical to the
        os.environ.get fallback beside them, and APNS_HOST *contradicted* one — compose forced
        production while app.py defaulted to sandbox, so the two files disagreed about the same
        question and only one was ever read.
        """
        import re
        defaults = dict(re.findall(
            r'^(\w+) *= *(?:Path\()?os\.environ\.get\("(?:\w+)", *"([^"]+)"\)',
            self.app, re.M))
        for name, value in defaults.items():
            self.assertNotIn(f"      {name}: {value}", self.compose,
                             f"{name} restates app.py's own default; delete the compose line")

    def test_optional_settings_are_not_listed_in_compose_at_all(self):
        # env_file passes everything in .env to the container, so an optional setting needs no line
        # here. Listing them cost a paragraph of explanation each and made the file read as though
        # six Apple credentials were mandatory — the compose file had become the documentation.
        # .env.example is the reference; this file is the wiring.
        self.assertIn("env_file:", self.compose)
        for name in ("APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "CANOPY_URL", "CANOPY_INVITE_CODE"):
            self.assertNotIn(f"{name}:", self.compose,
                             f"{name} is optional and reaches the container via env_file; a line "
                             f"here only invites another paragraph explaining it")

    def test_no_stale_claim_that_the_apns_values_are_fail_hard(self):
        # The comment that made this file look credential-heavy described a `:?` that had already
        # been changed to `:-` two lines below it.
        self.assertNotIn("`:?` fails the deploy loudly instead of at the first push", self.compose)


class ConfigIsGroupedByWhatItIsFor(unittest.TestCase):
    """Trellis does two independent things and they need different setup.

    Someone who only wants push should be able to see that at a glance, and — more importantly —
    should not be stopped by a MakerWorld dependency. The collections volume is declared `external`,
    so a name that does not exist refuses to start the container at all, which takes push down with
    it and reports a volume rather than the feature.
    """

    def setUp(self):
        import pathlib as _p
        here = _p.Path(__file__).parent
        self.example = (here / ".env.example").read_text()
        self.compose = (here / "docker-compose.yml").read_text()

    def test_the_example_says_what_each_feature_needs(self):
        self.assertIn("PUSH", self.example)
        self.assertIn("COLLECTIONS", self.example)
        self.assertIn("Either works without the other", self.example)

    def test_the_collections_mount_warns_that_it_blocks_startup(self):
        # The trap: the error names a volume, so it reads as "Trellis is broken" when what was
        # actually lost is push, which never touches this mount.
        self.assertIn("MAKERWORLD COLLECTIONS ONLY", self.compose)
        self.assertIn("start the container AT ALL", self.compose)

    def test_the_only_required_value_is_marked_as_required_for_both(self):
        self.assertIn("required for BOTH", self.example)
        self.assertIn("Required for BOTH features", self.compose)
