# Task: Add Push Notification Sending to happy-server

## Context

The Happy mobile app registers Expo push tokens and sends them to the server (`POST /v1/push-tokens`), which stores them in the `AccountPushToken` database table. However, the server never actually sends push notifications. When the user's phone is backgrounded/closed and the CLI agent finishes work or needs input, the user gets no notification.

This task adds the missing push dispatch logic. It is **server-side only** — no changes to the mobile app are needed.

## Architecture Overview

The server's event system works like this:

- `EventRouter` (singleton at `sources/app/events/eventRouter.ts`) maps `userId -> Set<ClientConnection>`
- Connections can be `user-scoped` (mobile app), `session-scoped` (CLI), or `machine-scoped` (daemon)
- `emitUpdate()` sends persistent events via socket.io to matching connections
- If a user has no connections, events are silently dropped (client catches up via sequence numbers on reconnect)

Push notifications should fire when `emitUpdate()` is called for a push-worthy event and the user has **no active `user-scoped` connections** (mobile app is backgrounded/closed).

All message content is end-to-end encrypted — the server cannot read it, so notification text must be generic.

## Files to Modify

| File | Action |
|---|---|
| `package.json` | Add `expo-server-sdk` dependency |
| `sources/modules/push/push.ts` | **Create** — push sending module |
| `sources/modules/push/push.spec.ts` | **Create** — tests |
| `sources/app/events/eventRouter.ts` | Add ~10 lines to `emitUpdate()` to trigger push |

## Subagent Tasks

### Task 1: Add dependency (model: haiku)

```
yarn add expo-server-sdk
```

Verify it was added to `package.json` and `yarn.lock`.

---

### Task 2: Create `sources/modules/push/push.ts` (model: sonnet)

Create the push notification module. It exports two functions:

#### `maybeSendPush(userId: string, eventType: UpdateEvent['type']): void`

Called from `emitUpdate()`. Fire-and-forget (no await at call site).

Logic:
1. Check if `eventType` is in the push-worthy set (see table below). If not, return immediately.
2. Debounce per-user: use a `Map<string, NodeJS.Timeout>` keyed by userId. If a timer already exists for this user, clear it and reset. Use a 1500ms trailing-edge debounce window. When the timer fires, call `sendPushNotification()`.
3. This ensures rapid `new-message` events during an active session produce exactly one notification.

#### `sendPushNotification(userId: string, title: string, body: string): Promise<void>` (not exported)

Internal function that actually sends the push:
1. Fetch all push tokens: `db.accountPushToken.findMany({ where: { accountId: userId }, select: { token: true } })`
2. Filter to valid Expo tokens using `Expo.isExpoPushToken(token)`
3. Build `ExpoPushMessage[]` with `{ to, title, body, sound: 'default' }`
4. Chunk with `expo.chunkPushNotifications(messages)` and send with `expo.sendPushNotificationsAsync(chunk)`
5. Collect tokens where the ticket has `status: 'error'` and `details.error === 'DeviceNotRegistered'`
6. Delete stale tokens: `db.accountPushToken.deleteMany({ where: { accountId: userId, token: { in: staleTokens } } })`
7. Log errors with `log({ module: 'push', level: 'error' }, ...)`

#### Push-worthy events and notification text

| Event type | Title | Body |
|---|---|---|
| `new-message` | `Happy` | `New message from your agent` |
| `new-feed-post` | `Happy` | `You have a new notification` |

Store this as a `Map` or `Record` constant (`PUSH_COPY`).

#### Code conventions to follow
- Use 4-space indentation
- Use absolute imports with `@/` prefix (e.g., `import { db } from '@/storage/db'`)
- Functional style, no classes
- Add a JSDoc comment at the top explaining the module's purpose
- Import types: `UpdateEvent` from `@/app/events/eventRouter`
- Import `Expo, { ExpoPushMessage, ExpoPushTicket }` from `expo-server-sdk`
- Import `db` from `@/storage/db`
- Import `log` from `@/utils/log`

---

### Task 3: Create `sources/modules/push/push.spec.ts` (model: sonnet)

Write tests using vitest. Follow the pattern in `sources/utils/lru.spec.ts` (import from vitest, describe/it/expect blocks).

Mock these modules at the top of the file:
- `expo-server-sdk` — mock `Expo` class: `isExpoPushToken`, `chunkPushNotifications`, `sendPushNotificationsAsync`
- `@/storage/db` — mock `db.accountPushToken.findMany` and `db.accountPushToken.deleteMany`
- `@/utils/log` — mock as `vi.fn()`

Use `vi.useFakeTimers()` for debounce tests and `vi.advanceTimersByTime(1500)` to trigger.

Test cases:
1. **Does not send for non-push-worthy event types** — call `maybeSendPush(userId, 'update-session')`, advance timers, verify `sendPushNotificationsAsync` was NOT called
2. **Sends for push-worthy events** — call `maybeSendPush(userId, 'new-message')`, advance timers, verify `sendPushNotificationsAsync` WAS called with correct title/body
3. **Debounces rapid calls into one send** — call `maybeSendPush` 5 times in quick succession, advance timers, verify `sendPushNotificationsAsync` was called exactly once
4. **Removes DeviceNotRegistered tokens** — mock `sendPushNotificationsAsync` to return `{ status: 'error', details: { error: 'DeviceNotRegistered' } }`, verify `db.accountPushToken.deleteMany` was called with the stale token
5. **Does nothing if user has no tokens** — mock `findMany` to return `[]`, verify `sendPushNotificationsAsync` was NOT called
6. **Skips invalid (non-Expo) tokens** — mock `isExpoPushToken` to return false, verify `sendPushNotificationsAsync` was NOT called

---

### Task 4: Modify `sources/app/events/eventRouter.ts` (model: sonnet)

Add the push trigger to the `emitUpdate()` method. This is a small, surgical change.

**Add import at top of file:**
```typescript
import { maybeSendPush } from '@/modules/push/push';
```

**Add after the `this.emit(...)` call inside `emitUpdate()` (after line 243):**
```typescript
// Send push notification when mobile app is not connected
const pushEventTypes: Set<string> = new Set(['new-message', 'new-feed-post']);
if (pushEventTypes.has(params.payload.body.t)) {
    const connections = this.userConnections.get(params.userId);
    const hasUserScoped = connections
        ? [...connections].some(c => c.connectionType === 'user-scoped')
        : false;
    if (!hasUserScoped) {
        maybeSendPush(params.userId, params.payload.body.t as UpdateEvent['type']);
    }
}
```

**Why this works:**
- `user-scoped` connections are the mobile app. If none exist, the app is closed/backgrounded.
- `session-scoped` (CLI) and `machine-scoped` (daemon) connections are NOT the phone — a CLI can be active while the phone is closed.
- `maybeSendPush` is fire-and-forget (no await), so it never blocks event routing.
- The `pushEventTypes` set can be moved to module scope as a constant for efficiency.

---

### Task 5: Build and verify (model: haiku)

1. Run `yarn build` — verify no TypeScript errors
2. Run `yarn test` — verify all tests pass including the new push spec
3. Rebuild the container image: `podman build -t happy-server:latest .`
4. Restart: `podman compose down && podman compose up -d`
5. Wait 15 seconds, then check: `podman logs happy-server-happy-server-1 | tail -10` — should show `Ready` with no errors

---

## What This Does NOT Change

- `sources/app/api/routes/pushRoutes.ts` — token CRUD already works correctly
- `sources/app/api/socket/sessionUpdateHandler.ts` — no changes needed
- `sources/app/feed/feedPost.ts` — no changes needed
- Database schema / Prisma — `AccountPushToken` model already exists
- `sources/main.ts` — no initialization needed (Expo SDK connects lazily)
- Mobile app — no changes needed, App Store build works as-is

## End-to-End Verification

1. Open the Happy app on the phone, confirm it's authenticated against the self-hosted server
2. Background the app (swipe to home screen)
3. In a terminal, run a `happy` CLI command that triggers agent output
4. Within a few seconds, a push notification should appear on the phone: **"Happy — New message from your agent"**
5. Check server logs: `podman logs happy-server-happy-server-1 | grep push` — should see module: 'push' entries
6. If no notification appears, check:
   - `podman logs happy-server-happy-server-1 | grep -E "(push|DeviceNotRegistered)"` for errors
   - Verify push tokens exist: `curl -k -H "Authorization: Bearer YOUR_TOKEN" https://bms4.lan:3030/v1/push-tokens`
   - Verify iOS notification permissions are granted for the Happy app
   - Note: push token registration is skipped in `__DEV__` builds — must use a production/preview build from the App Store or TestFlight
