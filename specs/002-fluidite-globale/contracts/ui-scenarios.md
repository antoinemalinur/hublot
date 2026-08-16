# UI contracts: Fluidité globale

## Scenario `streaming-pressure`

The debug-only relay creates one real `ACPConnection` and one real `ChatSession`,
then emits at least 1,000 ordered `agent_message_chunk` notifications while a
long thread is visible.

Required accessibility contract:

| Identifier | Observable behavior |
|---|---|
| `composer-input` | Hittable during the burst; typed text appears. |
| `composer-action` | Reflects that typed content can be sent. |
| `streaming-pressure-complete` | Appears only after the last expected character has crossed `ChatSession`. |
| `streaming-pressure-revisions` | Reports a revision count no greater than the success budget. |

The fixture must not initialize `turns` with the expected response. The response
must traverse JSON decoding, `ACPConnection.broadcast`, `ChatSession.apply`, the
coalescing boundary and SwiftUI rendering.

## Scenario `project-loading`

The debug-only relay responds to initialization and project listing, but retains
both `session/list` and `hublot/instructions` until an independent deadline.

Required accessibility contract:

| Identifier | Observable behavior |
|---|---|
| `project-row-hublot` | The test touches the real project row. |
| `sessions-loading` | Visible after navigation and before the retained list returns. |
| `new-session` | Hittable while the list is retained. |
| `sessions-back` | Carries the selected project name immediately. |

The relay records both pending methods so the domain test can prove they overlap;
the UI test verifies the user's gesture and destination geometry.

## Compatibility

Existing identifiers and scenarios remain unchanged. No snapshot is renewed by
this feature because the loading state is a new dynamic scenario and production
screens at rest keep their current appearance.
