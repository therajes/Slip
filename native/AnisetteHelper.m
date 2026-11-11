#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>

static NSString *const unavailableMessage = @"macOS did not release local Apple authentication data to Slip. Remote compatibility requires an external authentication-data provider and may show a different device in Apple's sign-in alert.";

static BOOL isNonemptyString(id value) {
    if (![value isKindOfClass:NSString.class] || [[(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] == 0) return NO;
    for (NSUInteger index = 0; index < [value length]; index++) {
        unichar character = [value characterAtIndex:index];
        if (character < 0x20 || character >= 0x7f) return NO;
    }
    return YES;
}

static BOOL hasObjectMethodSignature(Class type, SEL selector, unsigned int argumentCount) {
    Method method = class_getClassMethod(type, selector);
    if (method == NULL || method_getNumberOfArguments(method) != argumentCount) return NO;
    char *returnType = method_copyReturnType(method);
    BOOL valid = returnType != NULL && strcmp(returnType, "@") == 0;
    free(returnType);
    for (unsigned int index = 2; valid && index < argumentCount; index++) {
        char *argumentType = method_copyArgumentType(method, index);
        valid = argumentType != NULL && strcmp(argumentType, "@") == 0;
        free(argumentType);
    }
    return valid;
}

// Reject partial and conflicting aliases rather than pairing values from different
// responses. The machine ID and one-time password must come from one source.
static NSDictionary *validatedAuthenticationData(id headers, id deviceID, NSString **failureCode) {
    if (![headers isKindOfClass:NSDictionary.class] || [(NSDictionary *)headers count] == 0) {
        *failureCode = @"headers_unavailable";
        return nil;
    }
    id machineID = headers[@"X-Apple-MD-M"];
    id password = headers[@"X-Apple-MD"];
    id alternateMachineID = headers[@"X-Apple-I-MD-M"];
    id alternatePassword = headers[@"X-Apple-I-MD"];
    BOOL hasPrimaryPair = isNonemptyString(machineID) && isNonemptyString(password);
    BOOL hasAlternatePair = isNonemptyString(alternateMachineID) && isNonemptyString(alternatePassword);
    BOOL hasAnyPrimary = machineID != nil || password != nil;
    BOOL hasAnyAlternate = alternateMachineID != nil || alternatePassword != nil;
    if ((hasAnyPrimary && !hasPrimaryPair) || (hasAnyAlternate && !hasAlternatePair)) {
        *failureCode = @"headers_incomplete";
        return nil;
    }
    if (hasPrimaryPair && hasAlternatePair &&
        (![machineID isEqual:alternateMachineID] || ![password isEqual:alternatePassword])) {
        *failureCode = @"headers_conflict";
        return nil;
    }
    if (!hasPrimaryPair && hasAlternatePair) {
        machineID = alternateMachineID;
        password = alternatePassword;
    }
    if (!hasPrimaryPair && !hasAlternatePair) {
        *failureCode = @"headers_unavailable";
        return nil;
    }
    if (!isNonemptyString(deviceID)) {
        *failureCode = @"identity_unavailable";
        return nil;
    }
    NSString *localUserID = [[deviceID dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    if (!isNonemptyString(localUserID)) {
        *failureCode = @"identity_unavailable";
        return nil;
    }
    return @{
        @"machineId": machineID,
        @"oneTimePassword": password,
        @"deviceId": deviceID,
        @"localUserId": localUserID,
        @"routingInfo": @"84215040"
    };
}

static NSDictionary *localAuthenticationData(NSString **failureCode) {
    NSBundle *framework = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AOSKit.framework"];
    if (framework == nil || ![framework loadAndReturnError:NULL]) {
        *failureCode = @"framework_unavailable";
        return nil;
    }
    Class utilities = NSClassFromString(@"AOSUtilities");
    SEL otpSelector = NSSelectorFromString(@"retrieveOTPHeadersForDSID:");
    SEL deviceSelector = NSSelectorFromString(@"machineUDID");
    if (utilities == Nil || !hasObjectMethodSignature(utilities, otpSelector, 3) || !hasObjectMethodSignature(utilities, deviceSelector, 2)) {
        *failureCode = @"api_unavailable";
        return nil;
    }

    // AOSKit's production DSID returns a matched machine ID and one-time password.
    id headers = ((id (*)(id, SEL, id))objc_msgSend)(utilities, otpSelector, @"-2");
    id deviceID = ((id (*)(id, SEL))objc_msgSend)(utilities, deviceSelector);
    return validatedAuthenticationData(headers, deviceID, failureCode);
}

#ifndef SLIP_BUILD_VERSION
#define SLIP_BUILD_VERSION "development"
#endif
int main(int argc, const char *argv[]) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts(SLIP_BUILD_VERSION);
        return 0;
    }
    @autoreleasepool {
        BOOL checkOnly = argc == 2 && strcmp(argv[1], "--check") == 0;
        NSDictionary *result = nil;
        NSString *failureCode = @"invalid_arguments";
        @try {
            if (argc == 1 || checkOnly) result = localAuthenticationData(&failureCode);
        } @catch (__unused NSException *exception) {
            // Exception reasons can contain private values. Only this stable code
            // crosses the process boundary; never serialize the exception itself.
            failureCode = @"api_exception";
            result = nil;
        }
        BOOL available = result != nil;
        NSDictionary *response = checkOnly
            ? (available ? @{@"available": @YES, @"code": @"ready"}
                : @{@"available": @NO, @"code": failureCode, @"message": unavailableMessage})
            : (available ? result : @{@"code": failureCode, @"error": unavailableMessage});
        NSData *json = [NSJSONSerialization dataWithJSONObject:response options:0 error:NULL];
        if (json == nil) return 1;
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return available ? 0 : 1;
    }
}
