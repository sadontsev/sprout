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


def choose(env: dict, default_url: str = "https://canopy.sadontsev.com"):
    """Returns (canopy_url, relay_mode) or raises SystemExit, mirroring app.py."""
    explicit = env.get("CANOPY_URL", "").rstrip("/")
    signs_locally = bool(env.get("APNS_KEY_ID"))
    if explicit and signs_locally:
        raise SystemExit("both configured")
    url = explicit or ("" if signs_locally else default_url)
    return url, bool(url)


class BackendChoice(unittest.TestCase):
    def test_a_bare_deployment_relays_to_the_authors_service(self):
        # The default that makes the App Store build work for someone with no Apple developer
        # account. Before this, an unconfigured deployment exited at startup and the user's only
        # symptom was that nothing ever arrived.
        url, relay = choose({})

        self.assertEqual(url, "https://canopy.sadontsev.com")
        self.assertTrue(relay)

    def test_setting_an_apns_key_opts_out_of_the_relay(self):
        # Signing locally is a deliberate choice, and it must not be overridden by a default that
        # would then be refused as "both configured".
        url, relay = choose({"APNS_KEY_ID": "ABCD123456"})

        self.assertEqual(url, "")
        self.assertFalse(relay)

    def test_an_explicit_url_wins(self):
        url, relay = choose({"CANOPY_URL": "https://canopy.example.com"})

        self.assertEqual(url, "https://canopy.example.com")
        self.assertTrue(relay)

    def test_a_trailing_slash_is_stripped(self):
        # Every path is concatenated onto this, so a trailing slash produces //v1/push.
        url, _ = choose({"CANOPY_URL": "https://canopy.example.com/"})

        self.assertEqual(url, "https://canopy.example.com")

    def test_configuring_both_is_still_fatal(self):
        # The default must not silently resolve this. Ambiguity about who signs would surface as a
        # failure at the first push rather than at boot.
        with self.assertRaises(SystemExit):
            choose({"CANOPY_URL": "https://canopy.example.com", "APNS_KEY_ID": "ABCD123456"})

    def test_an_empty_apns_key_id_does_not_count_as_opting_out(self):
        # compose passes ${APNS_KEY_ID:-}, so the variable is PRESENT and empty on every deployment
        # that did not set it. Treating presence as intent would disable the relay for everyone.
        url, relay = choose({"APNS_KEY_ID": ""})

        self.assertEqual(url, "https://canopy.sadontsev.com")
        self.assertTrue(relay)

    def test_an_empty_canopy_url_falls_back_to_the_default(self):
        url, _ = choose({"CANOPY_URL": ""})

        self.assertEqual(url, "https://canopy.sadontsev.com")

    def test_matches_the_module_constant(self):
        """The guard against this file drifting from the code it mirrors."""
        source = (pathlib.Path(__file__).parent / "app.py").read_text()
        match = re.search(r'^DEFAULT_CANOPY_URL = "([^"]+)"', source, re.M)

        self.assertIsNotNone(match, "app.py must define DEFAULT_CANOPY_URL at module scope")
        self.assertEqual(
            match.group(1), "https://canopy.sadontsev.com",
            "the default relay changed in app.py; update this test and the self-hosting guide",
        )

    def test_the_default_is_https(self):
        # It carries a tenant bearer on every request. Plain http would put it on the wire.
        url, _ = choose({})
        self.assertTrue(url.startswith("https://"))


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
