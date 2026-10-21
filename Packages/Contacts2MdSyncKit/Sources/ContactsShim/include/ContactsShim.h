// ContactsShim: a minimal Objective-C layer over Contacts.framework APIs that
// signal failure by raising NSExceptions, which Swift cannot catch.
//
// -[CNContactStore enumeratorForChangeHistoryFetchRequest:error:] is the main
// offender: it (and the returned enumerator while being drained) can raise for
// an invalid/expired history token or a missing entitlement instead of
// returning an NSError. The category below catches those exceptions and maps
// them onto NSError so Swift sees an ordinary `throws` function.

#import <Contacts/Contacts.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for exceptions converted by ContactsShim.
FOUNDATION_EXPORT NSErrorDomain const C2MContactsShimErrorDomain;

/// Error codes in `C2MContactsShimErrorDomain`.
typedef NS_ERROR_ENUM(C2MContactsShimErrorDomain, C2MContactsShimErrorCode) {
    /// An Objective-C exception was raised. `userInfo` carries the exception
    /// name (`C2MExceptionNameKey`) and reason (`NSLocalizedFailureReasonErrorKey`).
    C2MContactsShimErrorCodeObjCException = 1,
};

/// `userInfo` key holding the raised exception's `name`.
FOUNDATION_EXPORT NSString *const C2MExceptionNameKey;

/// Result of a change-history fetch: the fully drained events plus the token
/// to persist and pass as `startingToken` next time.
@interface C2MChangeHistoryResult : NSObject

@property (nonatomic, readonly, copy) NSArray<CNChangeHistoryEvent *> *events;
@property (nonatomic, readonly, copy, nullable) NSData *currentHistoryToken;

- (instancetype)initWithEvents:(NSArray<CNChangeHistoryEvent *> *)events
           currentHistoryToken:(nullable NSData *)currentHistoryToken NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CNContactStore (C2MContactsShim)

/// Fetches all contact change-history events since `startingToken`
/// (or the full history when `nil`), unified, fetching `keysToFetch`
/// for added/updated contacts.
///
/// The enumerator is drained inside the exception guard, so exceptions
/// raised lazily during iteration are converted too.
///
/// - Returns: The events and new token, or `nil` with `error` set.
- (nullable C2MChangeHistoryResult *)c2m_changeHistoryEventsFor:(NSArray<id<CNKeyDescriptor>> *)keysToFetch
                                                          token:(nullable NSData *)startingToken
                                                          error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(c2m_changeHistoryEvents(for:token:));

@end

NS_ASSUME_NONNULL_END
