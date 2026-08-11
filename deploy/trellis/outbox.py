"""A small durable outbox for alert banners.

Live-Activity updates deliberately have no queue: they carry *state*, the poll loop resends the
current state every tick, and a queued update would deliver progress that was already stale by the
time it drained. Failing and letting the next tick resend is both simpler and more correct.

Alert banners are the opposite. They carry *events* — a print finished, a print halted, the plate
is cool — and the edge that produced one fires exactly once. `_last_kind` advances whether or not
the push succeeded, so a transient failure used to lose the notification permanently: the printer
finished, nobody was told, and nothing would ever tell them. That is the failure this module
exists to prevent, and it is worth persisting across restarts because a restart during an outage
is precisely when it would otherwise happen.

The queue is deliberately small and boring:

* **Deduplicated by key**, so a retry storm cannot deliver five "print finished" banners.
* **Bounded**, so an outage cannot grow the state file without limit.
* **Given up on**, because a banner about a print that ended two hours ago is noise, not news.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any

# Backoff between attempts, in seconds. The last entry is roughly an hour after the event, which is
# about as late as a "your print finished" banner is still worth sending.
BACKOFF_S = (0.0, 30.0, 120.0, 600.0, 1800.0)
MAX_ATTEMPTS = len(BACKOFF_S)
# Bounded so a long outage cannot grow registrations.json without limit. Oldest go first: a stale
# banner is worth less than a fresh one.
MAX_PENDING = 64


@dataclass
class Alert:
    key: str
    title: str
    body: str
    urgent: bool = True
    attempts: int = 0
    next_at: float = 0.0

    def to_json(self) -> dict:
        return asdict(self)

    @classmethod
    def from_json(cls, raw: Any) -> "Alert | None":
        if not isinstance(raw, dict) or not raw.get("key"):
            return None
        return cls(
            key=str(raw["key"]),
            title=str(raw.get("title", "")),
            body=str(raw.get("body", "")),
            urgent=bool(raw.get("urgent", True)),
            attempts=int(raw.get("attempts", 0)),
            next_at=float(raw.get("next_at", 0.0)),
        )


@dataclass
class Outbox:
    pending: list[Alert] = field(default_factory=list)

    def add(self, key: str, title: str, body: str, urgent: bool = True, now: float = 0.0) -> bool:
        """Queue an alert. Returns False if one with this key is already waiting.

        Deduplication is by key rather than by content: the same event re-observed must not produce
        a second banner, which is what a retry storm would otherwise do.
        """
        if any(a.key == key for a in self.pending):
            return False

        self.pending.append(Alert(key=key, title=title, body=body, urgent=urgent, next_at=now))
        # Drop the oldest rather than refusing the newest: during an outage the most recent event is
        # the one still worth telling someone about.
        while len(self.pending) > MAX_PENDING:
            self.pending.pop(0)
        return True

    def due(self, now: float) -> list[Alert]:
        return [a for a in self.pending if a.next_at <= now]

    def succeeded(self, key: str) -> None:
        self.pending = [a for a in self.pending if a.key != key]

    def failed(self, key: str, now: float) -> None:
        """Record a failed attempt, scheduling the next one — or giving up.

        Giving up is a feature. A banner about a print that ended an hour ago is noise, and an entry
        that retried forever would outlive the thing it describes.
        """
        for alert in list(self.pending):
            if alert.key != key:
                continue
            alert.attempts += 1
            if alert.attempts >= MAX_ATTEMPTS:
                self.pending.remove(alert)
                return
            alert.next_at = now + BACKOFF_S[alert.attempts]
            return

    def to_json(self) -> list[dict]:
        return [a.to_json() for a in self.pending]

    @classmethod
    def from_json(cls, raw: Any) -> "Outbox":
        if not isinstance(raw, list):
            return cls()
        loaded = [Alert.from_json(item) for item in raw]
        return cls(pending=[a for a in loaded if a is not None][-MAX_PENDING:])

    def __len__(self) -> int:
        return len(self.pending)
