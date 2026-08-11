"""Client for Canopy, the hosted APNs relay.

In RELAY mode this service holds no APNs key. It forwards pushes to Canopy,
which decides whether this tenant may push to that token and signs on our
behalf. Two rules shape everything here:

* **A Canopy HTTP status is not an APNs status.** They answer different
  questions -- "did the request work" and "what did Apple say about this
  token" -- and the caller's token hygiene may only ever consume the second.
  `PushResult` therefore keeps them in separate fields, and `apns_status` is
  ``None`` unless Canopy actually reached Apple.
* **`not_bound` is not `not_owner`.** The first is routine housekeeping after
  a release or an expiry and means "re-claim"; the second means another tenant
  holds the token and our authority was taken. Conflating them would make
  ordinary housekeeping look like an attack, and would suspend every token on
  this box at once after a Canopy restore.

The transport is injected so the whole module is testable without a network.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable, Optional


class Outcome(str, Enum):
    """What happened to a request, at the transport layer."""

    DELIVERED = "delivered"
    """Canopy reached APNs. ``apns_status`` is meaningful."""

    NOT_BOUND = "not_bound"
    """Nobody holds this token. Routine; the answer is to re-claim, not to
    suspend."""

    NOT_OWNER = "not_owner"
    """Another tenant holds it. Our authority was taken: suspend the token."""

    RATE_LIMITED = "rate_limited"
    """Back off and retry."""

    TRANSPORT = "transport"
    """Never got an answer. Retry; touch no registration."""

    REFUSED = "refused"
    """Canopy declined the request itself -- oversized payload, unknown push
    type. Never a statement about the token."""


@dataclass(frozen=True)
class PushResult:
    outcome: Outcome
    apns_status: Optional[int] = None
    apns_reason: str = ""
    detail: str = ""

    @property
    def token_is_dead(self) -> bool:
        """Whether APNs said this token will never work again.

        False for every non-delivered outcome by construction. This is the one
        place the two-field split pays off: a Canopy-side 400 or a dial timeout
        cannot reach the code that drops registrations.
        """
        if self.outcome is not Outcome.DELIVERED:
            return False
        return self.apns_status == 410 or (
            self.apns_status == 400 and self.apns_reason == "BadDeviceToken"
        )

    @property
    def should_retry(self) -> bool:
        return self.outcome in (Outcome.TRANSPORT, Outcome.RATE_LIMITED)


@dataclass(frozen=True)
class ClaimResult:
    ok: bool
    reason: str = ""
    outcome: Outcome = Outcome.DELIVERED

    @property
    def definitive(self) -> bool:
        """Whether Canopy actually decided.

        A transport failure is not a decision: the registration must fail to the
        phone so its retry drives convergence, rather than the phone believing a
        lost claim succeeded and never trying again.
        """
        return self.outcome is not Outcome.TRANSPORT

    @property
    def needs_reattest(self) -> bool:
        return self.reason == "reattest_required"


@dataclass(frozen=True)
class Credentials:
    tenant_id: str
    tenant_secret: str
    recovery_code: str

    @property
    def bearer(self) -> str:
        return f"{self.tenant_id}.{self.tenant_secret}"


class CanopyError(RuntimeError):
    pass


# A transport takes (method, path, json_body, bearer) and returns
# (status_code, decoded_json_or_None). It raises on a genuine transport failure.
Transport = Callable[[str, str, Optional[dict], Optional[str]], tuple[int, Any]]


class CanopyClient:
    """Talks to one Canopy deployment as one tenant."""

    def __init__(self, transport: Transport, credentials: Optional[Credentials] = None):
        self._transport = transport
        self.credentials = credentials

    # --- enrollment ---

    def enroll(self, invite_code: str = "", recovery_code: str = "") -> Credentials:
        """Create a tenant, or re-adopt one with a recovery code.

        Re-adoption is what keeps a rebuilt server's existing bindings
        reachable: the tenant identity is preserved, only the secret changes.
        """
        body: dict[str, str] = {}
        if invite_code:
            body["invite_code"] = invite_code
        if recovery_code:
            body["recovery_code"] = recovery_code

        status, payload = self._call("POST", "/v1/enroll", body, authed=False)
        if status != 201:
            raise CanopyError(f"enroll failed: {status} {_reason(payload)}")
        creds = Credentials(
            tenant_id=payload["tenant_id"],
            tenant_secret=payload["tenant_secret"],
            recovery_code=payload["recovery_code"],
        )
        self.credentials = creds
        return creds

    # --- claims ---

    def challenge(self, purpose: str) -> str:
        status, payload = self._call("POST", "/v1/challenges", {"purpose": purpose})
        if status != 201:
            raise CanopyError(f"challenge failed: {status} {_reason(payload)}")
        return payload["challenge"]

    def vouch(self, token: str, apns_environment: str) -> None:
        """Ask Canopy to prove the token is reachable on the claiming device.

        Answers 202 whatever APNs does with the silent push, so this call can
        never be used to tell a live token from a dead one.
        """
        status, payload = self._call(
            "POST", "/v1/vouch", {"token": token, "apns_environment": apns_environment}
        )
        if status not in (202, 429):
            raise CanopyError(f"vouch failed: {status} {_reason(payload)}")

    def claim(self, claim_body: dict) -> ClaimResult:
        """Forward a phone's claim. The body is passed through verbatim.

        Trellis deliberately does not construct or alter it: every field is
        inside the device's signed client data, so touching one would only
        invalidate the signature -- which is exactly the property that makes a
        compromised Trellis unable to bind somebody else's token.
        """
        try:
            status, payload = self._call("POST", "/v1/claims", claim_body)
        except Exception as exc:  # noqa: BLE001 - any transport failure
            return ClaimResult(ok=False, reason=str(exc), outcome=Outcome.TRANSPORT)

        if status == 204:
            return ClaimResult(ok=True)
        if status in (400, 403, 429):
            return ClaimResult(ok=False, reason=_reason(payload))
        return ClaimResult(ok=False, reason=_reason(payload) or f"status {status}")

    # --- pushing ---

    def push(
        self,
        token: str,
        push_type: str,
        priority: int,
        payload: dict,
        collapse_id: str = "",
    ) -> PushResult:
        body: dict[str, Any] = {
            "token": token,
            "push_type": push_type,
            "priority": priority,
            "payload": payload,
        }
        if collapse_id:
            body["collapse_id"] = collapse_id

        try:
            status, data = self._call("POST", "/v1/push", body)
        except Exception as exc:  # noqa: BLE001
            return PushResult(outcome=Outcome.TRANSPORT, detail=str(exc))

        if status == 200:
            return PushResult(
                outcome=Outcome.DELIVERED,
                apns_status=_int_or_none(data, "apns_status"),
                apns_reason=str((data or {}).get("apns_reason") or ""),
            )
        reason = _reason(data)
        if status == 403 and reason == "not_owner":
            return PushResult(outcome=Outcome.NOT_OWNER, detail=reason)
        if status == 403:
            # not_bound, or any other 403: nobody holds it, so re-claim.
            return PushResult(outcome=Outcome.NOT_BOUND, detail=reason)
        if status == 429:
            return PushResult(outcome=Outcome.RATE_LIMITED, detail=reason)
        if status in (502, 503, 504) or status >= 500:
            return PushResult(outcome=Outcome.TRANSPORT, detail=reason or f"status {status}")
        return PushResult(outcome=Outcome.REFUSED, detail=reason or f"status {status}")

    # --- binding lifecycle ---

    def release(self, token: str) -> bool:
        """Stop counting this binding against the cap. Not a deletion: the row
        keeps its anchors, so a released token is never reopened to a
        first-come claim."""
        status, _ = self._call("POST", "/v1/bindings/release", {"token": token})
        return status == 204

    def delete(self, token: str) -> bool:
        """Return the token to unbound. This is the reset-pairing recovery
        path, and the only transition that makes a token claimable again."""
        status, _ = self._call("DELETE", "/v1/bindings", {"token": token})
        return status == 204

    def healthy(self) -> bool:
        try:
            status, _ = self._call("GET", "/v1/health", None, authed=False)
        except Exception:  # noqa: BLE001
            return False
        return status == 200

    # --- plumbing ---

    def _call(self, method: str, path: str, body: Optional[dict], authed: bool = True):
        bearer = None
        if authed:
            if self.credentials is None:
                raise CanopyError("not enrolled")
            bearer = self.credentials.bearer
        return self._transport(method, path, body, bearer)


def _reason(payload: Any) -> str:
    if isinstance(payload, dict):
        return str(payload.get("error") or "")
    return ""


def _int_or_none(payload: Any, key: str) -> Optional[int]:
    if not isinstance(payload, dict):
        return None
    value = payload.get(key)
    return int(value) if isinstance(value, (int, float)) else None
