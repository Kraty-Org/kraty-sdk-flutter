# Kraty Flutter SDK: public surface (v0.6.0)

Canonical method + type listing for `kraty` (Dart package). Update this
file in the same commit as any signature change.

All methods sit on the `Kraty` facade unless noted. Every async method
returns a `Future`. The optional `as` field on resource calls is for
server-side tooling.

## `Kraty` facade

```dart
Kraty(KratyClientOptions options)

String? get activeExternalPlayerId
Future<(String externalPlayerId, String secret)> ensureIdentity()
Future<void> signIn(String externalPlayerId, String secret)
Future<void> logout()
Future<void> close()  // dispose resources

// Finalization catch-up (docs/05b). Fires exactly once per board across the
// live SSE `finalized` event AND boards that ended while the player was away.
void Function() onFinalized(FinalizationListener cb)      // returns unsubscribe
Future<List<FinalizationResult>> checkFinalizations()     // call on app foreground/reconnect
Future<void> dismiss(MembershipRef ref)                   // ack one handled result
Future<int> clearReported()                               // bulk-drop delivered entries
```

`FinalizationResult` = `{ MembershipRef ref; String reason; SelfEntry? self; List<FinalStanding>? standings; String? eventKey }`; `reason` uses the `FinalizationReason` consts (`sessionTerminated` \| `windowClosed` \| `periodRolled` \| `finalized`). Registry persistence is injectable via `KratyClientOptions.membershipStore` (`SharedPreferencesMembershipStore` in Flutter, `InMemoryMembershipStore` in pure-Dart).

## `kraty.events`: `EventsClient`

```dart
Future<List<EventListing>> listForPlayer({String? as})
Future<StartAttemptResponse> start(String eventKey, {Map<String, Object?>? playerContext, String? idempotencyKey, String? as})
Future<ProgressResponse> progress(String eventKey, String attemptId, ProgressInput input, {String? as})
```

## `kraty.leaderboards`: `LeaderboardsClient`

The dashboard-configured cross-event boards. Addressed by stable
game-scoped **key**. Wire endpoints:

- `GET /sdk/v1/leaderboards` (list the game's boards)
- `GET /sdk/v1/leaderboards/:key`
- `GET /sdk/v1/leaderboards/:key/standings`
- `GET /sdk/v1/leaderboards/:key/periods`
- `POST /sdk/v1/players/:externalId/leaderboards/:key/join`
- `POST /sdk/v1/players/:externalId/leaderboards/:key/score`

```dart
Future<List<LeaderboardSummary>> list()
Future<Leaderboard>            read(String key, {LeaderboardReadOptions? options})
Future<Leaderboard>            join(String key, {int? limit, String? segment, String? as})
Future<BoardStandings>         standings(String key, {StandingsReadOptions? options})
Future<LeaderboardScoreResult> submitScore(String key, num value, {String? segment, String? idempotencyKey, String? as})
Future<LeaderboardPeriods>     listPeriods(String key, {int? limit})
```

`LeaderboardReadOptions`:
- `int? limit`: 1–200, default 50 server-side
- `String? segment`: bucket value; required only for `context` segmentation. Omit for `progression`-segmented boards (server derives the caller's division); unsegmented boards ignore it
- `String? period`: `"current"` (default) or an ISO timestamp from `LeaderboardPeriod.periodStartedAt`
- `bool includeSelf`: when true, response includes `self: { rank, score }` (live periods only)
- `String? externalId`: required when `includeSelf` is true; lazily resolved otherwise

`join` enrols the active player at score 0 without submitting a score; returns the current standings with `joined: true`. Idempotent (never resets an existing score). Pass `segment` for `context` boards; omit for `progression` boards (server derives the division from the caller's balance).

`standings` is a multi-segment read. Returns one `StandingsSegment` block per segment selected by `scope`. `StandingsReadOptions`:
- `String? scope`: `'self_segment'`, `'mine'`, `'segment'`, `'all'` (default `'all'`)
- `String? segment`: required when `scope == 'segment'` on a segmented board
- `String? period`: `'current'` (default) or an ISO timestamp from `listPeriods`
- `String? externalId`: auto-resolved for `self_segment` / `mine`
- `int? limit`: per-segment top-N (1..200, default 50)
- `int? maxSegments`: cap on returned segment blocks (1..100, default 20)

`BoardStandings`: `key`, `leaderboardId`, `scope`, `resetCadence`, `scoreAggregation`, `period`, `List<StandingsSegment> segments`, `bool segmentsTruncated`.
`StandingsSegment`: `String? segment`, `bool participated`, `int? selfRank`, `List<LeaderboardEntry> entries`.

`submitScore` submits a score for the active player directly to the board, outside an event attempt. `segment` is required only for `context` segmentation; omit for `progression` boards (server derives the division); unsegmented boards ignore it. Errors: `client_scoring_disabled` (403, board is server-only), `score_not_supported` (400, progression-ranked board), `not_found` (404), `validation_failed` (400). Returns `LeaderboardScoreResult`:
- `String leaderboardId`
- `num score`
- `int? rank`

## `kraty.eventLeaderboards`: `EventLeaderboardsClient`

The auto-generated per-event-window leaderboard. Addressed by the
**UUID** returned in `events.start(...)`'s `attempt.leaderboardId`.
Includes Server-Sent Events live streaming. Wire endpoints:

- `GET /sdk/v1/event-leaderboards/:id`
- `GET /sdk/v1/event-leaderboards/:id/stream`
- `POST /sdk/v1/players/:externalId/event-leaderboards/:id/join`

```dart
Future<EventLeaderboard>       read(String leaderboardId, {EventLeaderboardReadOptions? options})
Future<EventLeaderboard>       join(String leaderboardId, {int? limit, String? as})
Future<LeaderboardStream>      live(String leaderboardId)
LiveLeaderboardSubscription   subscribe(String leaderboardId, {Duration pollInterval = const Duration(seconds: 15)})
```

`join` enrols the active player in the current event window at score 0 without starting a scoring attempt; returns the board with `joined: true`. Idempotent. Throws `KratyApiError` with code `conflict` (409) once the window has finalized.

`EventLeaderboardReadOptions`:
- `int? limit`
- `bool includeSelf`
- `String? externalId`

`EventLeaderboard` read response includes `bool finalized` and, when finalized, `String? finalizedReason` (`session_terminated` \| `window_closed`), which powers the finalization catch-up's session-vs-window distinction.

`LiveLeaderboardSubscription`:
- `Stream<LeaderboardStreamEvent> events`: broadcast stream, deduped by `(participantId, score)`
- `Stream<Object> errors`: transport / poll failures (non-fatal)
- `Future<void> cancel()`: idempotent

Set `pollInterval: Duration.zero` to disable polling (SSE-only).

## `kraty.grants`: `GrantsClient`

```dart
Future<List<Grant>>      listPending({int? limit, String? as})
Future<Grant>            claim(String grantId, {String? idempotencyKey, String? as})
Future<OpenCrateResponse> open(String grantId, {String? idempotencyKey, String? as})
Future<CollectAllResult> collectAll({String? as})
```

`CollectAllResult`:
- `List<Grant> opened`
- `List<Grant> claimed`
- `List<CollectAllFailure> failures`
- `bool get hasFailures`

## `kraty.lobbies`: `LobbiesClient`

```dart
Future<Lobby> read(String lobbyId)
```

## `kraty.inventory`: `InventoryClient`

```dart
Future<List<PlayerItemHolding>> list({String? as})
Future<ConsumeItemResult>       consume(String itemKey, ConsumeItemInput input, {String? as})
```

## `kraty.wallet`: `WalletClient`

```dart
Future<List<PlayerWalletHolding>> list({String? as})
Future<DebitWalletResult>         debit(String economyKey, DebitWalletInput input, {String? as})
```

## `kraty.dailyLogin`: `DailyLoginClient`

```dart
Future<DailyLogin?> read({String? as})
```

`GET /sdk/v1/players/:p/daily-login`. The game's daily login calendar:
`days[{ day, entries }]`, `afterLastDay`, `loginStreak`, `currentDay`,
`paidToday`, `todayGrantId`, `nextDayAt`, `itemKey`. `null` when the game
has none or it is off for the key's environment. Read-only: the request's
session is what pays today's reward (a `daily_login` grant).

## `kraty.offers`: `OffersClient`

```dart
Future<List<Offer>>            list({int? limit, int? level, String? as})
Future<OfferImpressionResult>  markShown(String instanceId, {String? idempotencyKey, String? as})
Future<Offer>                  dismiss(String instanceId, {String? idempotencyKey, String? as})
Future<OfferTriggerResult>     trigger(OfferTriggerInput input, {Map<String, Object?>? playerContext, String? idempotencyKey, String? as})
Future<OfferClaimResult>       claim(String instanceId, {required int tier, String? idempotencyKey, String? as})

// OfferTriggerInput (sealed)
const OfferTriggerInput.failEvent(String key, {int? consecutive})
const OfferTriggerInput.resourceDepleted(String resource, {required int required, required int available, int? secondsToRegen})
const OfferTriggerInput.levelReached(int level)

String canonicalTransactionId({required String store, String? transactionId, String? orderId, String? purchaseToken})
```

`GET /sdk/v1/players/:p/offers` (`limit` ≤ 20, default 10; `level` for
`level_reached` offers), `POST …/offers/:instanceId/impression`, `…/dismiss`
and `…/offers/triggers` (docs/26). Listing is not an impression: call
`markShown` when the offer is on screen (it starts a `first_shown` timer).
The SDK generates `idempotencyKey` when omitted. Sell
`offer.current.skus[store]` and pass `offer.instanceId` as
`TrackPurchaseInput.offerInstanceId`; when `result.offer.studioFulfils` is
true (the offer is set to game delivers; by default Kraty delivers, so do not grant it too) the game delivers `result.offer.contents` itself.
`trigger` answers the newly armed offers that can be shown now (empty when
none did). Win-back offers need no call.

Free chain tiers: `OfferTier.type` is `paid` or `free` (`isFree`). A free
tier has `storeProductKey == ''` (null on the wire, kept non-null so the
field isn't breaking), empty `skus` and `referencePriceMinor == 0`; never
send it to a store. `claim` is `POST …/offers/:instanceId/claim` with
`{idempotencyKey, tier}` (`tier` = the `offer.tier` the player tapped) and
answers `OfferClaimResult {claim: OfferClaim, offer}`: the chain moves to
the next tier (its timer starts now) or completes. When
`claim.studioFulfils` is true (the offer is set to game delivers; by default Kraty delivers, so do not grant it too) the game delivers
`claim.contents`. A refusal throws `KratyApiError` with `code ==
'conflict'`, `details['reason']` (`tier_changed`, `tier_not_free`,
`offer_closed`) and `details['offer']`, the offer now.

Revision 4 (docs/26 § 13): `Offer.variantKey` is the A/B variant this player
sees (`current`, `next` and `presentation` already reflect it; null for the
base config); `Offer.linkedEventKey` is the linked event's key (show the sale
on that event's screen), else null. `OfferClaim.variantKey` and
`PurchaseOfferResult.variantKey` name the variant claimed or sold.
`OfferImpressionResult.cappedReason` (`offer_cycle`, `offer_day`,
`global_session`, `global_day`, `global_gap`) and `retryAt` explain a
refused impression; respect `capped`. Re-rendering an offer already shown this
session is never refused by the game-wide caps.

`canonicalTransactionId` returns the id client and server must both report:
StoreKit 2 `transactionId` on the App Store, the `orderId` (`GPA.…`) on
Google Play (`GooglePlayPurchaseDetails.billingClientPurchase.orderId`; the
purchase token only without one), other stores unchanged.

## `kraty.guilds`: `GuildsClient`

```dart
Future<GuildClientConfig>       config({String? as})
Future<MyGuild?>                mine({String? as})
Future<GuildDetail>             get(String guildId, {String? as})
Future<List<GuildSummary>>      search(String query, {String? country, int? limit, int? offset, String? as})
Future<GuildSearchPage>         searchPage(String query, {String? country, int? limit, int? offset, String? as}) // guilds + nextOffset
Future<List<GuildSummary>>      recommended({String? country, int? limit, String? as})
Future<MyGuild>                 create({required String name, String? description, String? badge, String? country, String? joinType, Map<String, Object?>? metadata, String? as})
Future<GuildJoinResult>         join(String guildId, {String? message, String? as})
Future<List<GuildJoinRequest>>  myRequests({String? as})
Future<void>                    cancelRequest(String requestId, {String? as})
Future<GuildDetail>             updateProfile({String? name, ..., String? as})
Future<GuildLeaveResult>        leave({String? as})
Future<List<GuildJoinRequest>>  requests({String? as})
Future<GuildDetail>             acceptRequest(String requestId, {String? as})
Future<void>                    declineRequest(String requestId, {String? as})
Future<GuildDetail>             kick / promote / demote(String memberExternalId, {String? as})
Future<GuildDetail>             transferLeadership(String memberExternalId, {String? as})
Future<GuildHelpOverview>       help({String? as})
Future<GuildHelpRequest>        requestHelp({required String type, required String resourceKey, required int amount, String? as})
Future<GuildHelpDonation>       donate(String requestId, {int? amount, String? as})
Future<GuildHelpRequest>        cancelHelp(String requestId, {String? as})
```

`/sdk/v1/players/:p/guild*` and `/guilds*` (docs/25). One guild per player,
50 members max, leader / co-leader / member.

## `kraty.chat`: `ChatClient`

```dart
Future<ChatClientConfig>      config({String? as})
Future<ChatPreferences>       preferences({String? as})
Future<ChatPreferences>       setPreferences({bool? profanityFilter, bool resetProfanityFilter = false, String? allowDirectFrom, String? as})
Future<ChatConversationPage>  conversations({String? kind, int? limit, int? offset, String? as}) // conversations + nextOffset
Future<ChatUnread>            unread({String? as})
Future<ChatConversation>      conversation(String conversationId, {String? as})               // + members (groups)
Future<ChatConversation>      openDirect({String? externalPlayerId, String? friendCode, String? as}) // exactly one
Future<ChatConversation>      createGroup({required String title, List<String>? externalPlayerIds, Map<String, Object?>? metadata, String? as})
Future<ChatConversation>      updateGroup(String conversationId, {String? title, Map<String, Object?>? metadata, String? as})
Future<ChatConversation>      addMembers(String conversationId, List<String> externalPlayerIds, {String? as})
Future<void>                  removeMember(String conversationId, String externalPlayerId, {String? as})
Future<ChatConversation>      setRole(String conversationId, String externalPlayerId, String role, {String? as}) // owner | admin | member
Future<void>                  leave(String conversationId, {String? as})
Future<ChatConversation>      guild({String? as})                                              // 409 conflict when guildless
Future<List<ChatConversation>> channels({String? as})
Future<ChatConversation>      channel(String key, {String? as})
Future<ChatMessagePage>       messages(String conversationId, {int? before, int? after, int? limit, String? as}) // oldest -> newest + hasMore
Future<ChatMessage>           send(String conversationId, String text, {String? replyToId, String? clientMessageId, String? as})
Future<ChatMessage>           sendCustom(String conversationId, String customType, Object? payload, {String? text, String? replyToId, String? clientMessageId, String? as})
Future<ChatMessage>           editMessage(String conversationId, String messageId, String text, {String? as}) // own message, within editWindowSeconds
Future<void>                  deleteMessage(String conversationId, String messageId, {String? as})
Future<int>                   markRead(String conversationId, int seq, {String? as})          // returns lastReadSeq
Future<void>                  typing(String conversationId, {String? as})
Future<ChatConversation>      setConversationSettings(String conversationId, {DateTime? mutedUntil, bool unmute = false, bool? hidden, String? as})
Future<ChatStream>            live({List<String>? channels, String? as})                       // SSE
```

`/sdk/v1/players/:p/chat/*` (docs/26). A paid add-on: when it's off every
call throws `KratyApiError` with `isChatDisabled` (403 `chat_disabled`).
`send` / `sendCustom` generate a v4 UUID `clientMessageId` when none is
passed; reuse it to retry a send idempotently. Message `seq` is gapless and
ascending per conversation: the `before` / `after` cursor.
`editMessage` (`PATCH .../messages/:messageId` `{ text }`) edits the player's
own message while `ChatClientConfig.editWindowSeconds` (0 = editing off) has
not elapsed; the result has `ChatMessage.editedAt` (ISO string, null = never
edited; `edited` getter) set. Otherwise 403 `chat_edit_not_allowed`
(`isChatEditNotAllowed`); the filter and `chat_message_rejected` /
`chat_message_invalid` / 429 behave as on send.

`KratyClientOptions.chatProfanityFilter` (`bool?`, default null): when set,
every chat call and the stream send `X-Kraty-Chat-Filter: on|off` (the
stream also `?filter=on|off`). Null = the player's saved preference, then the
kind's default.

`ChatStream`: `Stream<ChatStreamEvent> events`, `Stream<Object> errors`,
`Future<void> cancel()`. No auto-reconnect; after reconnecting, catch up with
`messages(id, after: lastSeq)`. `ChatStreamEvent` is sealed:
`ChatReadyEvent` (`externalPlayerId`, `conversationIds`, `channels`),
`ChatMessageEvent` (`message`), `ChatMessageEditedEvent` (`message_edited`:
`message`, the full updated copy), `ChatMessageDeletedEvent`,
`ChatTypingEvent`, `ChatReadEvent`, `ChatConversationAddedEvent`
(`conversationKind`), `ChatConversationUpdatedEvent`,
`ChatConversationRemovedEvent`, `ChatRestrictionEvent` (`restrictionKind`),
`ChatRestrictionLiftedEvent`, `ChatCloseEvent` (server draining: reconnect),
`ChatUnknownEvent`. Each keeps `kind` (the SSE event name) and raw `data`.

## `kraty.moderation`: `ModerationClient`

```dart
Future<MyReport>         report({required String targetExternalPlayerId, required String category, String? context, String? comment, String? conversationId, List<String>? messageIds, String? guildId, String? as})
Future<List<MyReport>>   reports({int? limit, String? as})
Future<ModerationStatus> status({String? as})
Future<Restriction>      acknowledgeWarning(String restrictionId, {String? as})
```

`/sdk/v1/players/:p/reports` and `/moderation/*`. Works in every game (no
add-on). `category` / `context` take the `ReportCategory` / `ReportContext`
constants. `ModerationStatus.pendingWarnings` lists unacknowledged warnings.

## `kraty.players`: `PlayersClient`

```dart
Future<PlayerRegistration> register(String externalPlayerId, {bool force = false})
```

## `kraty.catalog`: `CatalogClient`

```dart
Future<Catalog> get()
```

## Polling helpers

```dart
Stream<List<Grant>> pollPendingGrants(GrantsClient grants, {PollPendingGrantsOptions? options})
Future<Lobby>       pollLobbyUntilActive(LobbiesClient lobbies, String lobbyId, {PollLobbyOptions? options})
```

## Secret stores

```dart
abstract class SecretStore { ... }
class InMemorySecretStore implements SecretStore        // tests
class DefaultSecretStore implements SecretStore         // best-effort default
class SharedPreferencesSecretStore implements SecretStore  // wraps shared_preferences
```

## DTOs (response shapes)

`Attempt`, `StartAttemptResponse`, `ProgressInput`, `ProgressResponse`,
`MilestoneFired`, `EventListing`, `EntryCost`, `EntryCostCurrency`,
`EntryCostItem`, `Leaderboard`, `LeaderboardSummary`, `EventLeaderboard`, `LeaderboardEntry`,
`LeaderboardSelf`, `LeaderboardPeriod`, `LeaderboardPeriods`, `Grant`,
`OpenCrateResponse`, `Lobby`, `PlayerItemHolding`, `PlayerWalletHolding`,
`DailyLogin`, `DailyLoginDay`,
`GuildClientConfig`, `GuildSummary`, `GuildMember`, `GuildDetail`, `MyGuild`, `GuildJoinRequest`,
`GuildJoinResult`, `GuildLeaveResult`, `GuildHelpRequest`,
`GuildHelpOverview`, `GuildHelpDonation`, `GuildPlayerRef`,
`ChatClientConfig`, `ChatKindSettings`, `ChatCustomType`, `ChatPreferences`,
`ChatConversation`, `ChatConversationPage`, `ChatPeer`, `ChatPostDenied`,
`ChatChannel`, `ChatChannelRequirement`, `ChatMember`, `ChatMessage`,
`ChatMessagePage`, `ChatSender`, `ChatPlayerRef`, `ChatUnread`,
`MyReport`, `ModerationStatus`, `Restriction`,
`PlayerRegistration`, `ConsumeItemInput`, `ConsumeItemResult`,
`DebitWalletInput`, `DebitWalletResult`, `Catalog`, `CatalogItem`,
`CatalogCurrency`, `RewardBundlePreview`, `RewardEntryPreview`,
`RewardPolicySummary`, `RewardPolicyTier`,
`Offer`, `OfferTier`, `OfferPresentation`, `OfferImpressionResult`,
`OfferTriggerInput` (`OfferFailEventTrigger`, `OfferResourceDepletedTrigger`,
`OfferLevelReachedTrigger`), `OfferTriggerResult`, `OfferClaim`, `OfferClaimResult`, `PurchaseOfferResult`.

`TrackPurchaseInput.offerInstanceId` (optional);
`TrackPurchaseResult.offer` (`PurchaseOfferResult?`, null when not attributed).

## Errors

```dart
class KratyApiError extends Error      // non-2xx: has code, status, message
class KratyNetworkError extends Error  // transport / parse failure
```

`KratyApiError` boolean helpers:
`isLobbyForming`, `isInsufficientEntryCost`, `isPlayerSecretInvalid`,
`isPlayerAlreadyRegistered`, `isEntryRequirementFailed`,
`isNoLeaderboard`, `isNoActiveWindow`, `isMaxAttemptsReached`,
`isAttemptExpired`, `isAttemptCompleted`, `isChatDisabled`, `isChatMuted`,
`isChatBanned`, `isChatEditNotAllowed`, `isChatRateLimited`
(`chat_rate_limited` or `chat_slow_mode`; `details['retryAfterSeconds']`).
