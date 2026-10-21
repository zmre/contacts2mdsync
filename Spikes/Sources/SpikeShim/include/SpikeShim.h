// SpikeShim: minimal Objective-C helpers for the spike harness.
//
// Contacts.framework reports some failures by raising NSExceptions (unfetched
// keys, bad history tokens, entitlement problems), which Swift cannot catch.
// This mirrors the ContactsShim pattern in Contacts2MdSyncKit but exposes the
// extra knobs the spikes need (excluded authors, unify, group changes).

#import <Contacts/Contacts.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const C2MSpikeShimErrorDomain;

typedef NS_ERROR_ENUM(C2MSpikeShimErrorDomain, C2MSpikeShimErrorCode) {
    /// An Objective-C exception was raised; userInfo carries name and reason.
    C2MSpikeShimErrorCodeObjCException = 1,
};

FOUNDATION_EXPORT NSString *const C2MSpikeExceptionNameKey;

/// Runs `block`, converting any raised NSException into `error`.
/// Returns NO if an exception was raised.
FOUNDATION_EXPORT BOOL C2MSpikeTry(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

@interface C2MSpikeHistoryResult : NSObject
@property (nonatomic, readonly, copy) NSArray<CNChangeHistoryEvent *> *events;
@property (nonatomic, readonly, copy, nullable) NSData *currentHistoryToken;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface CNContactStore (C2MSpikeShim)

/// Fetches and fully drains change-history events since `token` (nil = from
/// scratch, which yields DropEverything + a full snapshot), inside @try.
- (nullable C2MSpikeHistoryResult *)c2mspike_historySince:(nullable NSData *)token
                                         excludingAuthors:(NSArray<NSString *> *)excludedAuthors
                                                    unify:(BOOL)unify
                                            includeGroups:(BOOL)includeGroups
                                                    error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(c2mspike_history(since:excludingAuthors:unify:includeGroups:));

@end

NS_ASSUME_NONNULL_END
