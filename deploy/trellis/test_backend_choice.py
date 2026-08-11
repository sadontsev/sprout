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


class DirectModeNeedsTheWholeCredentialSet(unittest.TestCase):
    """A key id alone is not a complete signing configuration.

    compose enforced this with ${APNS_TEAM_ID:?...} until that had to become :- so an unset value
    could reach app.py. The guard that replaced it checked only APNS_KEY_ID — a proxy for "the
    DIRECT set is complete", not the same question — so a deployment with a key id and a blank team
    id booted and signed every APNs JWT with an empty issuer, and APNs answered 403
    InvalidProviderToken on every push forever.
    """

    REQUIRED = ("APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC")

    def missing(self, env: dict):
        return [n for n in self.REQUIRED if not env.get(n)]

    def test_a_complete_set_is_accepted(self):
        env = {"APNS_KEY_ID": "K", "APNS_TEAM_ID": "T", "APNS_TOPIC": "com.example.app"}
        self.assertEqual(self.missing(env), [])

    def test_a_blank_team_id_is_caught(self):
        env = {"APNS_KEY_ID": "K", "APNS_TEAM_ID": "", "APNS_TOPIC": "com.example.app"}
        self.assertEqual(self.missing(env), ["APNS_TEAM_ID"])

    def test_an_absent_topic_is_caught(self):
        env = {"APNS_KEY_ID": "K", "APNS_TEAM_ID": "T"}
        self.assertEqual(self.missing(env), ["APNS_TOPIC"])

    def test_the_module_actually_checks_all_three(self):
        import pathlib as _p
        source = (_p.Path(__file__).parent / "app.py").read_text()
        for name in self.REQUIRED:
            self.assertIn(f'"{name}"', source)
        self.assertIn('_missing = [n for n in ("APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC")', source,
                      "the guard must name every variable a local signer needs")


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

    def test_the_apns_key_mount_does_not_invent_a_directory(self):
        # Docker creates a MISSING bind source as a DIRECTORY. Defaulting the mount to a
        # plausible-looking path made <secrets-dir>/apns_key.p8 a folder on every machine
        # without a key there — which is every relay deployment.
        self.assertIn("${APNS_KEY_FILE:-/dev/null}", self.compose)

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

    def test_they_are_documented_where_someone_configuring_would_look(self):
        import pathlib as _p
        example = (_p.Path(__file__).parent / ".env.example").read_text()
        for name in ("APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "CANOPY_URL", "CANOPY_INVITE_CODE"):
            self.assertIn(name, example, "dropping it from compose must not lose it entirely")

    def test_no_stale_claim_that_the_apns_values_are_fail_hard(self):
        # The comment that made this file look credential-heavy described a `:?` that had already
        # been changed to `:-` two lines below it.
        self.assertNotIn("`:?` fails the deploy loudly instead of at the first push", self.compose)
