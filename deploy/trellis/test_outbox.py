import unittest

from outbox import BACKOFF_S, MAX_ATTEMPTS, MAX_PENDING, Alert, Outbox


class TestQueueing(unittest.TestCase):
    def test_an_alert_is_due_immediately(self):
        o = Outbox()
        self.assertTrue(o.add("1:complete", "done", "body", now=100.0))
        self.assertEqual([a.key for a in o.due(100.0)], ["1:complete"])

    def test_duplicate_keys_are_refused(self):
        # The edge that produces an alert can be re-observed while the first send is
        # still pending; without dedup that delivers the same banner twice.
        o = Outbox()
        o.add("1:complete", "done", "body", now=0.0)
        self.assertFalse(o.add("1:complete", "done again", "body", now=0.0))
        self.assertEqual(len(o), 1)

    def test_distinct_events_coexist(self):
        o = Outbox()
        o.add("1:complete", "a", "b", now=0.0)
        o.add("2:error", "c", "d", now=0.0)
        self.assertEqual(len(o), 2)


class TestRetry(unittest.TestCase):
    def test_a_failure_schedules_a_later_attempt(self):
        o = Outbox()
        o.add("1:complete", "done", "body", now=0.0)

        o.failed("1:complete", now=0.0)
        self.assertEqual(o.due(0.0), [], "a failed alert must not be retried immediately")
        self.assertEqual(len(o.due(BACKOFF_S[1])), 1)

    def test_backoff_lengthens(self):
        o = Outbox()
        o.add("k", "t", "b", now=0.0)

        seen = []
        now = 0.0
        for _ in range(MAX_ATTEMPTS - 1):
            o.failed("k", now=now)
            if not o.pending:
                break
            seen.append(o.pending[0].next_at - now)
            now = o.pending[0].next_at

        self.assertEqual(seen, sorted(seen), "each retry must wait at least as long as the last")
        self.assertGreater(seen[-1], seen[0])

    def test_it_eventually_gives_up(self):
        # A banner about a print that ended an hour ago is noise, and an entry that
        # retried forever would outlive the thing it describes.
        o = Outbox()
        o.add("k", "t", "b", now=0.0)
        for _ in range(MAX_ATTEMPTS):
            o.failed("k", now=0.0)
        self.assertEqual(len(o), 0)

    def test_success_removes_it(self):
        o = Outbox()
        o.add("k", "t", "b", now=0.0)
        o.succeeded("k")
        self.assertEqual(len(o), 0)

    def test_failing_an_unknown_key_is_harmless(self):
        o = Outbox()
        o.failed("nope", now=0.0)  # must not raise
        self.assertEqual(len(o), 0)


class TestBounds(unittest.TestCase):
    def test_the_queue_is_bounded_and_drops_the_oldest(self):
        # A long outage must not grow the state file without limit, and the newest
        # event is the one still worth telling someone about.
        o = Outbox()
        for i in range(MAX_PENDING + 10):
            o.add(f"k{i}", "t", "b", now=float(i))

        self.assertEqual(len(o), MAX_PENDING)
        self.assertEqual(o.pending[-1].key, f"k{MAX_PENDING + 9}")
        self.assertNotIn("k0", [a.key for a in o.pending])


class TestPersistence(unittest.TestCase):
    def test_round_trip(self):
        # Persisted because a restart during an outage is exactly when an alert would
        # otherwise be lost — the edge that produced it has already advanced.
        o = Outbox()
        o.add("1:complete", "✅ done", "model.3mf", urgent=True, now=5.0)
        o.failed("1:complete", now=5.0)

        restored = Outbox.from_json(o.to_json())
        self.assertEqual(len(restored), 1)
        self.assertEqual(restored.pending[0].title, "✅ done")
        self.assertEqual(restored.pending[0].attempts, 1)
        self.assertEqual(restored.pending[0].next_at, o.pending[0].next_at)

    def test_junk_on_disk_does_not_crash_startup(self):
        # The load path runs before anything else; raising here would crash-loop the
        # container, and the recovery branch it would fall into resets all state.
        self.assertEqual(len(Outbox.from_json(None)), 0)
        self.assertEqual(len(Outbox.from_json("nonsense")), 0)
        self.assertEqual(len(Outbox.from_json([1, 2, {"no": "key"}])), 0)

    def test_an_oversized_file_is_truncated_on_load(self):
        raw = [{"key": f"k{i}", "title": "t", "body": "b"} for i in range(MAX_PENDING + 20)]
        self.assertEqual(len(Outbox.from_json(raw)), MAX_PENDING)

    def test_alert_from_json_tolerates_missing_fields(self):
        a = Alert.from_json({"key": "k"})
        self.assertIsNotNone(a)
        self.assertEqual(a.attempts, 0)
        self.assertTrue(a.urgent)


if __name__ == "__main__":
    unittest.main()
