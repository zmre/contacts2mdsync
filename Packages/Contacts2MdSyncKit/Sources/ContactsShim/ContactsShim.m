#import "ContactsShim.h"

NSErrorDomain const C2MContactsShimErrorDomain = @"com.zmre.contacts2mdsync.ContactsShim";
NSString *const C2MExceptionNameKey = @"C2MExceptionName";

static NSError *C2MErrorFromException(NSException *exception) {
    NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = @"The Contacts framework raised an exception.";
    userInfo[C2MExceptionNameKey] = exception.name ?: @"(unknown)";
    if (exception.reason != nil) {
        userInfo[NSLocalizedFailureReasonErrorKey] = exception.reason;
    }
    return [NSError errorWithDomain:C2MContactsShimErrorDomain
                               code:C2MContactsShimErrorCodeObjCException
                           userInfo:userInfo];
}

@implementation C2MChangeHistoryResult

- (instancetype)initWithEvents:(NSArray<CNChangeHistoryEvent *> *)events
           currentHistoryToken:(NSData *)currentHistoryToken {
    self = [super init];
    if (self) {
        _events = [events copy];
        _currentHistoryToken = [currentHistoryToken copy];
    }
    return self;
}

@end

@implementation CNContactStore (C2MContactsShim)

- (C2MChangeHistoryResult *)c2m_changeHistoryEventsFor:(NSArray<id<CNKeyDescriptor>> *)keysToFetch
                                                 token:(NSData *)startingToken
                                                 error:(NSError **)error {
    CNChangeHistoryFetchRequest *request = [[CNChangeHistoryFetchRequest alloc] init];
    request.startingToken = startingToken;
    request.additionalContactKeyDescriptors = keysToFetch;
    request.shouldUnifyResults = YES;
    request.mutableObjects = NO;

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

        // Drain inside @try: the enumerator can raise while iterating.
        NSMutableArray<CNChangeHistoryEvent *> *events = [NSMutableArray array];
        for (CNChangeHistoryEvent *event in result.value) {
            [events addObject:event];
        }
        return [[C2MChangeHistoryResult alloc] initWithEvents:events
                                          currentHistoryToken:result.currentHistoryToken];
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = C2MErrorFromException(exception);
        }
        return nil;
    }
}

- (BOOL)c2m_probeNoteAccessWithError:(NSError **)error {
    CNContactFetchRequest *request =
        [[CNContactFetchRequest alloc] initWithKeysToFetch:@[ CNContactIdentifierKey, CNContactNoteKey ]];
    @try {
        NSError *fetchError = nil;
        // Without the entitlement the fetch succeeds and the key is silently
        // unavailable (spike S2, macOS 27); older systems fail with error 102.
        // Reading .note is guarded by isKeyAvailable: an unfetched key raises.
        __block BOOL available = YES;
        BOOL ok = [self enumerateContactsWithFetchRequest:request
                                                    error:&fetchError
                                               usingBlock:^(CNContact *contact, BOOL *stop) {
                                                   available = [contact isKeyAvailable:CNContactNoteKey];
                                                   if (available) {
                                                       (void)contact.note;
                                                   }
                                                   *stop = YES;
                                               }];
        if (!ok) {
            if (error != NULL) {
                *error = fetchError;
            }
            return NO;
        }
        if (!available) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:CNErrorDomain
                                             code:CNErrorCodeUnauthorizedKeys
                                         userInfo:@{NSLocalizedDescriptionKey : @"CNContactNoteKey is unavailable"}];
            }
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = C2MErrorFromException(exception);
        }
        return NO;
    }
}

@end

NSData *C2MVCardData(NSArray<CNContact *> *contacts, NSError **error) {
    @try {
        return [CNContactVCardSerialization dataWithContacts:contacts error:error];
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = C2MErrorFromException(exception);
        }
        return nil;
    }
}
