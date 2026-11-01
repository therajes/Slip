#define main slip_anisette_helper_main
#include "../AnisetteHelper.m"
#undef main

// Synthetic fixtures only: this test never contacts Apple or asks AOSKit for
// tokens. Test the source-coherence boundary independently of OS availability.
int main(void) {
    @autoreleasepool {
        NSString *code = nil;
        NSDictionary *primary = @{@"X-Apple-MD-M": @"fixture-machine", @"X-Apple-MD": @"fixture-otp"};
        NSDictionary *alternate = @{@"X-Apple-I-MD-M": @"fixture-machine", @"X-Apple-I-MD": @"fixture-otp"};
        NSCAssert(validatedAuthenticationData(primary, @"fixture-device", &code) != nil, @"Primary pair should work");
        NSCAssert(validatedAuthenticationData(alternate, @"fixture-device", &code) != nil, @"Alternate pair should work");
        NSMutableDictionary *aliases = [primary mutableCopy];
        [aliases addEntriesFromDictionary:alternate];
        NSCAssert(validatedAuthenticationData(aliases, @"fixture-device", &code) != nil, @"Identical aliases should work");
        aliases[@"X-Apple-I-MD"] = @"other-fixture-otp";
        NSCAssert(validatedAuthenticationData(aliases, @"fixture-device", &code) == nil && [code isEqual:@"headers_conflict"], @"Conflicting pairs must fail");
        aliases = [alternate mutableCopy];
        aliases[@"X-Apple-MD-M"] = @"incomplete-primary";
        NSCAssert(validatedAuthenticationData(aliases, @"fixture-device", &code) == nil && [code isEqual:@"headers_incomplete"], @"Partial aliases must fail");
        NSCAssert(validatedAuthenticationData(@{}, @"fixture-device", &code) == nil && [code isEqual:@"headers_unavailable"], @"Empty headers must fail");
        NSCAssert(validatedAuthenticationData(primary, @"", &code) == nil && [code isEqual:@"identity_unavailable"], @"Missing identity must fail");
        NSCAssert(validatedAuthenticationData(@{@"X-Apple-MD-M": @"fixture-machine", @"X-Apple-MD": @"fixture\r\ninjected"}, @"fixture-device", &code) == nil, @"Control characters must fail");
        NSCAssert(validatedAuthenticationData(@{@"X-Apple-MD-M": @42, @"X-Apple-MD": @"fixture-otp"}, @"fixture-device", &code) == nil, @"Unexpected value types must fail");
        NSCAssert(validatedAuthenticationData(primary, @"fixture\nidentity", &code) == nil, @"Invalid identity must fail");
        puts("Local authentication helper fixture checks passed.");
    }
    return 0;
}
