/// Dart/Flutter SDK for the Kraty game-events platform.
///
/// Auto-stamped idempotency keys preserved across retries,
/// exponential retry with jitter, sealed error codes, adaptive
/// polling helpers, SSE leaderboard streaming, and a one-call
/// per-player bootstrap.
///
/// ```dart
/// import 'package:kraty/kraty.dart';
///
/// final kraty = Kraty(KratyClientOptions(apiKey: '...'));
/// final pending = await kraty.grants.listPending();
/// ```
library;

export 'src/client.dart' show
    KratyClient,
    KratyClientOptions,
    KratyRetryConfig,
    KratyRequestInfo;
export 'src/errors.dart' show
    KratyApiError,
    KratyErrorCode,
    KratyErrorPayload,
    KratyNetworkError,
    KratyChatNotSentError,
    KratyApiErrorIs;
export 'src/reconnecting_sse.dart' show KratyConnectionEvent, KratyConnectionState;
export 'src/leaderboard_stream.dart' show LeaderboardStream, LeaderboardStreamEvent;
export 'src/inventory_stream.dart'
    show InventoryStream, InventoryStreamEvent, InventoryEventOrigin;
export 'src/chat_stream.dart'
    show
        ChatStream,
        ChatStreamEvent,
        ChatStreamChannel,
        ChatReadyEvent,
        ChatMessageEvent,
        ChatMessageEditedEvent,
        ChatMessageDeletedEvent,
        ChatTypingEvent,
        ChatReadEvent,
        ChatConversationAddedEvent,
        ChatConversationUpdatedEvent,
        ChatConversationRemovedEvent,
        ChatRestrictionEvent,
        ChatRestrictionLiftedEvent,
        ChatCloseEvent,
        ChatUnknownEvent;
export 'src/sse.dart' show SseEvent, SseStream, openSseStream;
export 'src/resources.dart' show
    CatalogClient,
    ChatClient,
    DailyLoginClient,
    CollectAllFailure,
    CollectAllResult,
    EventLeaderboardsClient,
    EventsClient,
    FriendsClient,
    GrantsClient,
    GuildsClient,
    InventoryClient,
    LeaderboardsClient,
    LobbiesClient,
    OffersClient,
    ModerationClient,
    PlayersClient,
    PollLobbyOptions,
    PollPendingGrantsOptions,
    WalletClient,
    pollLobbyUntilActive,
    pollPendingGrants;
export 'src/types.dart' show
    Attempt,
    AttemptQuota,
    BlockedPlayer,
    BoardStandings,
    Catalog,
    CatalogCurrency,
    CatalogDerivedLevel,
    CatalogDerivedProgression,
    CatalogItem,
    ChatChannel,
    ChatChannelRequirement,
    ChatClientConfig,
    ChatConversation,
    ChatConversationPage,
    ChatCustomType,
    ChatKindSettings,
    ChatMember,
    ChatMessage,
    ChatMessagePage,
    ChatPeer,
    ChatPlayerRef,
    ChatPostDenied,
    ChatPreferences,
    ChatSender,
    ChatUnread,
    ConsumeItemInput,
    ConsumeItemResult,
    DailyLogin,
    DailyLoginDay,
    GuildClientConfig,
    GuildDetail,
    GuildHelpDonation,
    GuildHelpOverview,
    GuildHelpRequest,
    GuildJoinRequest,
    GuildJoinResult,
    GuildLeaveResult,
    GuildMember,
    GuildPlayerRef,
    GuildSearchPage,
    GuildSummary,
    MyGuild,
    DebitWalletInput,
    DebitWalletResult,
    EntryCost,
    EntryCostCurrency,
    EntryCostItem,
    EventLeaderboard,
    EventLeaderboardReadOptions,
    EventListing,
    FinishAttemptResponse,
    Friend,
    FriendCode,
    FriendRequest,
    FriendRequestPlayer,
    FriendRequests,
    FriendSearchResult,
    FriendTarget,
    Gift,
    GiftCatalog,
    GiftCounterparty,
    GiftableResource,
    Grant,
    GrantEntryInput,
    Leaderboard,
    LeaderboardEntry,
    LeaderboardPeriod,
    LeaderboardPeriods,
    LeaderboardReadOptions,
    LeaderboardScoreResult,
    LeaderboardSelf,
    LeaderboardSummary,
    Lobby,
    MilestoneFired,
    MilestoneRewardPreview,
    Offer,
    OfferClaim,
    OfferClaimResult,
    OfferFailEventTrigger,
    OfferImpressionResult,
    OfferLevelReachedTrigger,
    OfferPresentation,
    OfferResourceDepletedTrigger,
    OfferTier,
    OfferTriggerInput,
    OfferTriggerResult,
    ModerationStatus,
    MyReport,
    OpenCrateResponse,
    PlayerIdentity,
    PlayerItemHolding,
    PlayerPresence,
    PlayerRegistration,
    PlayerWalletHolding,
    ProgressInput,
    PurchaseOfferResult,
    ProgressResponse,
    ProgressionBand,
    ProgressionLimits,
    ReportCategory,
    ReportContext,
    Restriction,
    RewardBundlePreview,
    RewardEntryPreview,
    RewardPolicySummary,
    RewardPolicyTier,
    SendFriendRequestResult,
    SendGiftInput,
    ServerTime,
    StandingsReadOptions,
    StandingsSegment,
    Suggestion,
    TrackPurchaseInput,
    TrackPurchaseResult,
    canonicalTransactionId;

import 'src/client.dart';
import 'src/finalization.dart';
import 'src/resources.dart';
import 'src/types.dart'
    show ServerTime, TrackPurchaseInput, TrackPurchaseResult;

export 'src/secret_store.dart' show
    DefaultSecretStore,
    InMemorySecretStore,
    SecretStore,
    SharedPreferencesSecretStore;
export 'src/finalization.dart' show
    DefaultMembershipStore,
    EventLeaderboardStatus,
    FinalStanding,
    FinalizationListener,
    FinalizationReason,
    FinalizationResult,
    FinalizationTracker,
    InMemoryMembershipStore,
    MembershipKind,
    MembershipRef,
    MembershipStatus,
    MembershipStore,
    SelfEntry,
    SharedPreferencesMembershipStore,
    StandingKind,
    TrackedMembership;

/// Convenience facade: instantiate one [Kraty] instead of wiring
/// [KratyClient] + each resource client by hand. All resource clients
/// share the same underlying [KratyClient] so retry config, telemetry,
/// and the HTTP connection pool are shared.
///
/// The minimum boot is one line: the SDK lazily registers a self-
/// serve player on the first player-scoped call and persists the
/// identity via [KratyClientOptions.secretStore]:
///
/// ```dart
/// final kraty = Kraty(KratyClientOptions(apiKey: '...'));
/// final pending = await kraty.grants.listPending();
/// ```
class Kraty {
  final KratyClient client;
  final EventsClient events;
  final LeaderboardsClient leaderboards;
  final EventLeaderboardsClient eventLeaderboards;
  final GrantsClient grants;
  final LobbiesClient lobbies;
  final InventoryClient inventory;
  final WalletClient wallet;
  final PlayersClient players;
  final PurchasesClient purchases;
  final FriendsClient friends;
  final CatalogClient catalog;
  final DailyLoginClient dailyLogin;
  final GuildsClient guilds;
  final OffersClient offers;
  final ChatClient chat;
  final ModerationClient moderation;

  Kraty._({
    required this.client,
    required this.events,
    required this.leaderboards,
    required this.eventLeaderboards,
    required this.grants,
    required this.lobbies,
    required this.inventory,
    required this.wallet,
    required this.players,
    required this.purchases,
    required this.friends,
    required this.catalog,
    required this.dailyLogin,
    required this.guilds,
    required this.offers,
    required this.chat,
    required this.moderation,
  });

  factory Kraty(KratyClientOptions options) {
    final c = KratyClient(options);
    return Kraty._(
      client: c,
      events: EventsClient(c),
      leaderboards: LeaderboardsClient(c),
      eventLeaderboards: EventLeaderboardsClient(c),
      grants: GrantsClient(c),
      lobbies: LobbiesClient(c),
      inventory: InventoryClient(c),
      wallet: WalletClient(c),
      players: PlayersClient(c),
      purchases: PurchasesClient(c),
      friends: FriendsClient(c),
      catalog: CatalogClient(c),
      dailyLogin: DailyLoginClient(c),
      guilds: GuildsClient(c),
      offers: OffersClient(c),
      chat: ChatClient(c),
      moderation: ModerationClient(c),
    );
  }

  /// Record a real-money purchase for the active player.
  ///
  /// Shorthand for `kraty.purchases.track(...)`, promoted to the top
  /// level because reporting a purchase is a one-liner a game does
  /// from inside its store callback and shouldn't have to reach
  /// through a namespace for.
  ///
  /// Idempotent on `transactionId`, so calling it unconditionally on
  /// every restore — without tracking what you already reported — is
  /// the intended usage.
  Future<TrackPurchaseResult> trackPurchase(
    TrackPurchaseInput input, {
    String? as,
  }) =>
      purchases.track(input, as: as);

  /// The active player this SDK currently represents. Returns null
  /// until the first player-scoped call resolves the identity (or
  /// [ensureIdentity] is awaited explicitly).
  String? get activeExternalPlayerId => client.activeExternalPlayerId;

  /// Resolve the active player identity, lazily registering a fresh
  /// one if no persisted identity exists. Most games never call this,
  /// since any player-scoped resource method triggers it transparently.
  /// Reach for it only when you need the id available before the
  /// first request (e.g. to pre-greet the player by id).
  Future<({String externalPlayerId, String secret})> ensureIdentity() =>
      client.ensureIdentity();

  /// Forget the persisted identity. The next player-scoped call
  /// lazily registers a new player (or resumes a different id if the
  /// SecretStore holds one). Drop-in for a "sign out" button.
  Future<void> logout() => client.logout();

  /// Install an explicit identity on this SDK and persist it. Use
  /// when your own auth gave you back a Kraty `externalPlayerId` +
  /// `secret`, e.g. on a new device after a server-side device-link
  /// flow.
  Future<void> signIn({
    required String externalPlayerId,
    required String secret,
  }) =>
      client.signIn(externalPlayerId: externalPlayerId, secret: secret);

  /// Finalization catch-up (docs/05b). [onFinalized] fires when a board the
  /// player is in ends: live over SSE while subscribed, OR via
  /// [checkFinalizations] for boards that finalized while they were away
  /// (call it on app foreground / reconnect). Both paths deliver exactly
  /// once. [dismiss] / [clearReported] acknowledge handled results so they
  /// leave storage. Returns an unsubscribe function.
  void Function() onFinalized(FinalizationListener cb) =>
      client.onFinalized(cb);

  /// Poll tracked boards; report + return any that finalized while away.
  Future<List<FinalizationResult>> checkFinalizations() =>
      client.checkFinalizations();

  /// Acknowledge a handled finalization; drop it from the registry.
  Future<void> dismiss(MembershipRef ref) => client.dismiss(ref);

  /// Bulk-drop every already-reported membership. Returns the count.
  Future<int> clearReported() => client.clearReported();

  /// Server clock (anti-cheat timer). Fetch the backend's time so game timers
  /// can't be cheated by winding the device clock forward. [getServerTime] is a
  /// one-shot fetch; [syncTime] + [serverNow] give a tamper-proof local clock
  /// anchored to the server via a monotonic reference (call [syncTime] at
  /// startup and on app resume). Always compare [serverNow] / `epochMs` against
  /// an event's `endsAt`, never the device's own `DateTime.now()`.
  Future<ServerTime> getServerTime({String? timezone}) =>
      client.getServerTime(timezone: timezone);

  /// Anchor the tamper-proof clock. Call at startup and on app resume.
  Future<void> syncTime() => client.syncTime();

  /// True once [syncTime] has succeeded at least once.
  bool get isTimeSynced => client.isTimeSynced;

  /// Current server time as Unix epoch ms (UTC). Throws a [StateError] if
  /// [syncTime] hasn't run yet.
  int serverNowMs() => client.serverNowMs();

  /// Current server time as a UTC [DateTime]. Throws a [StateError] if
  /// [syncTime] hasn't run yet.
  DateTime serverNow() => client.serverNow();

  /// Releases the underlying HTTP client.
  void close() => client.close();
}
