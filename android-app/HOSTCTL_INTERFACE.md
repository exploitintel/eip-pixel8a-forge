# Forge companion hostctl interface

The companion is a thin client for one root-owned authority:

`/data/eip-cve-ops/eip-hostctl.sh`

The private installer grants the app package UID KernelSU's default root
profile. The KernelSU grant itself is full root; this interface is the narrower
application contract enforced by the APK source. The app constructs only the
fixed invocations below and exposes no arbitrary shell or argument input.

It can invoke only these exact, argument-free verbs:

- `status`
- `start`
- `park`
- `park-when-idle`
- `cancel-park-when-idle`
- `reconcile`
- `logs`

There is no free-form command, path, argument, Docker socket, or shell input in
the app. `start` converges Docker and Forge together to READY. `park` owns the
fail-closed shutdown guard. `park-when-idle` records a durable request to park
when Forge is idle; it does not promise to stop after a particular queue item.
`cancel-park-when-idle` cancels that pending park, and `reconcile` may park only
when the host authority proves it safe. The app does not reproduce pipeline
timing or container ownership rules. Wire names are isolated in
`HostctlCommand` so a later authority rename is local.

The UI asks for confirmation before Start, Park now, Park when idle, and Cancel
pending park. Closing a dialog or pressing Back dispatches nothing. The UI
checks current availability again on confirmation; the host remains the final
authority. Park now is offered only for a ready, idle host. Park when idle is
offered for ready or active work without an existing pending request. Open
WebUI requires valid status, Docker running, and UI health healthy, including
while a park request is pending. Lifecycle operations temporarily disable the
controls. Routine status refreshes do not disable otherwise available lifecycle
actions. The Quick Settings tile opens the app instead of dispatching a toggle.

The app never supplies arguments to the inspector. Internally, the lifecycle
authority streams `hostctl-state.mjs` into the healthy UI container with one
fixed `--park-proof` mode only for park and reconciliation. That proof accepts
the frozen `EIP_CVE_PUBLISH_ENABLED` value only when it is a case-insensitive
`false`. A true, missing, empty, or invalid value refuses park with an operator
reason because pre-intent publication work is otherwise invisible. The normal
status inspection has no argument and does not apply this conservative gate,
so publication configuration alone never turns READY or RUNNING into ATTENTION.
The current phone configuration is explicitly publish-disabled and retains its
existing lifecycle behavior.

`status` must exit zero and return one `key=value` field per line. Schema 1
requires exactly these keys:

```text
schema_version=1
system=parked|ready|running|degraded|attention
docker=running|stopped|ambiguous
forge=running|stopped|partial|unknown
work=idle|active|ambiguous
unknown_containers=0|<positive integer>|unknown
boot_policy=unmanaged
drain=off|pending|unknown
ui_health=healthy|starting|unhealthy|stopped|unknown
chat_health=healthy|starting|unhealthy|stopped|unknown
active_count=0|<positive integer>|unknown
active_kind=none|run|scout|qa|verify|publish|multiple|unknown
active_cve=none|CVE-YYYY-NNNN...|multiple|unknown
active_phase=none|router|research|branch|poc|publish|scout|qa|verify|multiple|unknown
active_started_at=none|<ISO-8601 UTC>|multiple|unknown
```

These health and active-work fields are sanitized operator visibility and are
also checked for internal coherence. Extra keys may extend schema 1, but
duplicate keys, missing core safety keys, malformed core values, timeouts, and
nonzero exits are ATTENTION states. While the foreground monitor is running,
an ATTENTION state retains a partial CPU wake lock. It also requests a Wi-Fi
lock only when Wi-Fi is the active transport, but that request is best-effort
and does not claim to prove screen-off connectivity on current Android
versions. Only a complete schema-1 status can prove READY, RUNNING,
PARK_PENDING, or PARKED.

Boot policy is deliberately unmanaged in this slice. The existing boot path
also owns binfmt and routing prerequisites, so the companion does not claim to
change boot behavior.

Main-run phases include `router`, `research`, `branch`, `poc`, and `publish`;
scout, QA, and verification lanes identify their own phase. A scout may
legitimately have no CVE yet.

A durable publication intent is reported as active publication work. That does
not cover the earlier v4 checkout-mutation window before intent creation. The
park-proof configuration gate closes that phone-side safety gap by refusing all
park convergence while publication is enabled. A future v4 publication latch
is required before publish-enabled Forge can be safely parkable.

Exit code 0 means the requested operation completed or was already satisfied.
Any other exit is a refusal or failure and must be shown to the operator. Root
command output is bounded by both the host authority and the app. Every fixed
invocation also runs under root-owned `/system/bin/timeout`: 60 seconds for
status, 25 seconds for marker/log operations, and 330 seconds for lifecycle
convergence. The Java waiter allows 70, 30, and 360 seconds respectively so the
root timeout can terminate its child before the app applies its fallback bound.
The open activity refreshes at most once per 60 seconds; the foreground safety
monitor has its own fixed-delay polling and is not paced by the screen. A
read-only status refresh disables only status-dependent read controls. It does
not disable lifecycle actions admitted by the last complete status; the host
authority revalidates every action before changing state.
