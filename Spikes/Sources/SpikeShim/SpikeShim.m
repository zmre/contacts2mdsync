#import "SpikeShim.h"

NSErrorDomain const C2MSpikeShimErrorDomain = @"com.zmre.contacts2mdsync.SpikeShim";
NSString *const C2MSpikeExceptionNameKey = @"C2MSpikeExceptionName";

static NSError *C2MSpikeErrorFromException(NSException *exception) {
    NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] =
        [NSString stringWithFormat:@"Objective-C exception %@", exception.name ?: @"(unknown)"];
    userInfo[C2MSpikeExceptionNameKey] = exception.name ?: @"(unknown)";
    if (exception.reason != nil) {
        userInfo[NSLocalizedFailureReasonErrorKey] = exception.reason;
    }
    return [NSError errorWithDomain:C2MSpikeShimErrorDomain
                               code:C2MSpikeShimErrorCodeObjCException
                           userInfo:userInfo];
}

BOOL C2MSpikeTry(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = C2MSpikeErrorFromException(exception);
        }
        return NO;
    }
}

@interface C2MSpikeHistoryResult ()
- (instancetype)initWithEvents:(NSArray<CNChangeHistoryEvent *> *)events token:(nullable NSData *)token;
@end

@implementation C2MSpikeHistoryResult

- (instancetype)initWithEvents:(NSArray<CNChangeHistoryEvent *> *)events token:(NSData *)token {
    self = [super init];
    if (self) {
        _events = [events copy];
        _currentHistoryToken = [token copy];
    }
    return self;
}

@end

@implementation CNContactStore (C2MSpikeShim)

- (C2MSpikeHistoryResult *)c2mspike_historySince:(NSData *)token
                                excludingAuthors:(NSArray<NSString *> *)excludedAuthors
                                           unify:(BOOL)unify
                                   includeGroups:(BOOL)includeGroups
                                           error:(NSError **)error {
    CNChangeHistoryFetchRequest *request = [[CNChangeHistoryFetchRequest alloc] init];
    request.startingToken = token;
    request.additionalContactKeyDescriptors = @[];
    request.shouldUnifyResults = unify;
    request.includeGroupChanges = includeGroups;
    request.mutableObjects = NO;
    if (excludedAuthors.count > 0) {
        request.excludedTransactionAuthors = excludedAuthors;
    }

    @try {
        NSError *fetchError = nil;
        CNFetchResult<NSEnumerator<CNChangeHistoryEvent *> *> *result =
            [self enumeratorForChangeHistoryFetchRequest:request error:&fetchError];
        if (result == nil) {
            if (error != NULL) {
                *error = fetchError;
            }
            return nil;
        }
        // Drain inside @try: the enumerator can raise lazily while iterating.
        NSMutableArray<CNChangeHistoryEvent *> *events = [NSMutableArray array];
        for (CNChangeHistoryEvent *event in result.value) {
            [events addObject:event];
        }
        return [[C2MSpikeHistoryResult alloc] initWithEvents:events token:result.currentHistoryToken];
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = C2MSpikeErrorFromException(exception);
        }
        return nil;
    }
}

@end
