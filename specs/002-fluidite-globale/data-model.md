# Data Model: Fluidité globale

## Pending stream fragment

Fragment textuel non encore publié dans le document.

| Field | Type | Rules |
|---|---|---|
| kind | `message` or `thought` | Deux types différents forment une frontière. |
| messageId | String | Deux identifiants différents forment une frontière. |
| text | String | Concaténation exacte, jamais tronquée ni normalisée. |
| scheduledAt | implicit task deadline | Publication au plus tard 25 ms après ouverture du tampon. |

State transitions:

```text
empty --text(id/kind)--> pending
pending --same id/kind--> pending (append)
pending --different id/kind--> published --> pending
pending --semantic boundary/deadline--> published --> empty
pending --close/disconnect/end--> published --> empty
```

Invariants:

- `published text + pending text` equals the ACP text received so far.
- A non-text event is never applied before the pending text that preceded it.
- At most one fragment and one scheduled flush task exist per `ChatSession`.

## Document revision

Monotone counter associated with the rendered conversation document.

| Field | Type | Rules |
|---|---|---|
| value | Int | Starts at zero; increments exactly once per visible batch mutation. |
| machine | MachineState | Recomputed before publishing the new revision. |

The revision changes for user turns, published assistant/thought text, tool
insert/update, permission, notice and streaming completion. It does not change
for activity heartbeat, quota, reconnect state, configuration, title or composer
state.

## Project resource loading

Two independent existing resources share a project identity:

| Resource | Loading signal | Success | Failure |
|---|---|---|---|
| Conversations | `isLoadingSessions` | replace `sessions` | clear sessions and expose failure |
| Instructions | no blocking UI state | replace `instructions` | keep `nil` |

`AppModel.open(project)` changes the screen first, resets both previous values,
starts both loads as structured children, and returns when both have settled.
Neither result is conditional on the other.
