/*
 
 TSKSPKIHashCache.m
 TrustKit
 
 Copyright 2015 The TrustKit Project Authors
 Licensed under the MIT license, see associated LICENSE file for terms.
 See AUTHORS file for the list of project authors.
 
 */

#import "TSKSPKIHashCache.h"
#import "../TSKLog.h"
#import <CommonCrypto/CommonDigest.h>

#if TARGET_OS_IOS && __IPHONE_OS_VERSION_MIN_REQUIRED <= 100000
// Need to support iOS before 10.0
// The one and only way to get a key's data in a buffer on iOS is to put it in the Keychain and then ask for the data back...
#define LEGACY_IOS_KEY_EXTRACTION 1
static const NSString *kTSKKeychainPublicKeyTag = @"TSKKeychainPublicKeyTag"; // Used to add and find the public key in the Keychain
#endif

#if !TARGET_OS_IPHONE && __MAC_OS_X_VERSION_MIN_REQUIRED < 101200
#define LEGACY_MACOS_KEY_EXTRACTION 1
#endif

#if TARGET_OS_WATCH || TARGET_OS_TV || (TARGET_OS_IOS &&__IPHONE_OS_VERSION_MAX_ALLOWED >= 100000) || (!TARGET_OS_IPHONE && __MAC_OS_X_VERSION_MAX_ALLOWED >= 101200)
#define UNIFIED_KEY_EXTRACTION 1
#endif


// Each key is a raw certificate data (for easy lookup) and each value is the certificate's raw SPKI data
typedef NSMutableDictionary<NSData *, NSData *> SpkiCacheDictionnary;

#pragma mark Missing ASN1 SPKI Headers

// These are the ASN1 headers for the Subject Public Key Info section of a certificate
static const unsigned char rsa2048Asn1Header[] = {
    0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
    0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
};

static const unsigned char rsa4096Asn1Header[] = {
    0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
    0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00
};

static const unsigned char ecDsaSecp256r1Asn1Header[] = {
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
    0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
    0x42, 0x00
};

static const unsigned char ecDsaSecp384r1Asn1Header[] = {
    0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
    0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00
};

// Careful with the order... must match how TSKPublicKeyAlgorithm is defined
static const unsigned char *asn1HeaderBytes[4] = { rsa2048Asn1Header, rsa4096Asn1Header,
    ecDsaSecp256r1Asn1Header, ecDsaSecp384r1Asn1Header };
static const unsigned int asn1HeaderSizes[4] = { sizeof(rsa2048Asn1Header), sizeof(rsa4096Asn1Header),
    sizeof(ecDsaSecp256r1Asn1Header), sizeof(ecDsaSecp384r1Asn1Header) };


@interface TSKSPKIHashCache ()
// Dictionnary to cache SPKI hashes instead of having to compute them on every connection
// We store one cache dictionnary per TSKPublicKeyAlgorithm we support
@property (nonatomic) NSMutableDictionary<NSNumber *, SpkiCacheDictionnary *> *subjectPublicKeyInfoHashesCache;
@property (nonatomic) dispatch_queue_t lockQueue;
@property (nonatomic) NSString *spkiCacheFilename;
@end

#if LEGACY_IOS_KEY_EXTRACTION
@interface TSKSPKIHashCache ()
@property (nonatomic) dispatch_queue_t keychainQueue;
@end

@interface TSKSPKIHashCache (LegacyIos)
- (NSData *)getPublicKeyDataFromCertificate_legacy_ios:(SecCertificateRef)certificate;
@end
#endif

#if LEGACY_MACOS_KEY_EXTRACTION
@interface TSKSPKIHashCache (LegacyMacOS)
- (NSData *)getPublicKeyDataFromCertificate_legacy_macos:(SecCertificateRef)certificate;
#endif

#if UNIFIED_KEY_EXTRACTION
@interface TSKSPKIHashCache (Unified)
- (NSData *)getPublicKeyDataFromCertificate_unified:(SecCertificateRef)certificate;
@end
#endif

@implementation TSKSPKIHashCache

- (instancetype)initWithIdentifier:(NSString *)uniqueIdentifier
{
    self = [super init];
    if (self) {
        // Initialize our locks
        _lockQueue = dispatch_queue_create("TSKSPKIHashLock", DISPATCH_QUEUE_CONCURRENT);

        _spkiCacheFilename = uniqueIdentifier; // if this value is nil, persistence will always fail.
        
        // First try to load a cached version from the filesystem
        _subjectPublicKeyInfoHashesCache = [self getSpkiCacheFromFileSystem];
        TSKLog(@"Loaded %lu SPKI cache entries from the filesystem", (unsigned long)_subjectPublicKeyInfoHashesCache.count);
        if (_subjectPublicKeyInfoHashesCache == nil)
        {
            _subjectPublicKeyInfoHashesCache = [NSMutableDictionary new];
        }
        
        // Initialize any sub-dictionnary that hasn't been initialized
        for (int i=0; i<=TSKPublicKeyAlgorithmLast; i++)
        {
            NSNumber *algorithmKey = @(i);
            if (_subjectPublicKeyInfoHashesCache[algorithmKey] == nil)
            {
                _subjectPublicKeyInfoHashesCache[algorithmKey] = [NSMutableDictionary new];
            }
            
        }
        
#if LEGACY_IOS_KEY_EXTRACTION
        _keychainQueue = dispatch_queue_create("TSKSPKIKeychainLock", DISPATCH_QUEUE_SERIAL);
        // Cleanup the Keychain in case the App previously crashed
        NSMutableDictionary * publicKeyGet = [[NSMutableDictionary alloc] init];
        [publicKeyGet setObject:(__bridge id)kSecClassKey forKey:(__bridge id)kSecClass];
        [publicKeyGet setObject:(kTSKKeychainPublicKeyTag) forKey:(__bridge id)kSecAttrApplicationTag];
        [publicKeyGet setObject:(__bridge id)(kCFBooleanTrue) forKey:(__bridge id)kSecReturnData];
        dispatch_sync(_keychainQueue, ^{
            SecItemDelete((__bridge CFDictionaryRef)(publicKeyGet));
        });
#endif
    }
    return self;
}

- (NSData *)hashSubjectPublicKeyInfoFromCertificate:(SecCertificateRef)certificate publicKeyAlgorithm:(TSKPublicKeyAlgorithm)publicKeyAlgorithm
{
    __block NSData *cachedSubjectPublicKeyInfo;
    NSNumber *algorithmKey = [NSNumber numberWithInt:publicKeyAlgorithm];
    
    // Have we seen this certificate before? Look for the SPKI in the cache
    NSData *certificateData = (__bridge_transfer NSData *)(SecCertificateCopyData(certificate));
    
    dispatch_sync(_lockQueue, ^{
        cachedSubjectPublicKeyInfo = _subjectPublicKeyInfoHashesCache[algorithmKey][certificateData];
    });
    
    if (cachedSubjectPublicKeyInfo)
    {
        TSKLog(@"Subject Public Key Info hash was found in the cache");
        return cachedSubjectPublicKeyInfo;
    }
    
    // We didn't this certificate in the cache so we need to generate its SPKI hash
    TSKLog(@"Generating Subject Public Key Info hash...");
    
    // First extract the public key bytes
    NSData *publicKeyData = [self getPublicKeyDataFromCertificate:certificate];
    if (publicKeyData == nil)
    {
        TSKLog(@"Error - could not extract the public key bytes");
        return nil;
    }
    
    
    // Generate a hash of the subject public key info
    NSMutableData *subjectPublicKeyInfoHash = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX shaCtx;
    CC_SHA256_Init(&shaCtx);
    
    // Add the missing ASN1 header for public keys to re-create the subject public key info
    CC_SHA256_Update(&shaCtx, asn1HeaderBytes[publicKeyAlgorithm], asn1HeaderSizes[publicKeyAlgorithm]);
    
    // Add the public key
    CC_SHA256_Update(&shaCtx, [publicKeyData bytes], (unsigned int)[publicKeyData length]);
    CC_SHA256_Final((unsigned char *)[subjectPublicKeyInfoHash bytes], &shaCtx);
    
    
    // Store the hash in our memory cache
    dispatch_barrier_sync(_lockQueue, ^{
        _subjectPublicKeyInfoHashesCache[algorithmKey][certificateData] = subjectPublicKeyInfoHash;
    });
    
    // Update the cache on the filesystem
    if (self.spkiCacheFilename.length > 0) {
        NSURL *cachesDirUrl = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
        NSURL *cacheUrl = [cachesDirUrl URLByAppendingPathComponent:self.spkiCacheFilename];
        NSData *serializedSpkiCache = [NSKeyedArchiver archivedDataWithRootObject:_subjectPublicKeyInfoHashesCache];
        if ([serializedSpkiCache writeToURL:cacheUrl atomically:YES] == NO)
        {
            NSAssert(false, @"Failed to write cache");
            TSKLog(@"Could not persist SPKI cache to the filesystem");
        }
    }
    
    return subjectPublicKeyInfoHash;
}

- (NSMutableDictionary<NSNumber *, SpkiCacheDictionnary *> *)getSpkiCacheFromFileSystem
{
    NSMutableDictionary *spkiCache;
    NSString *spkiCachePath = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0]
                               stringByAppendingPathComponent:self.spkiCacheFilename];
    NSData *serializedSpkiCache = [NSData dataWithContentsOfFile:spkiCachePath];
    if (serializedSpkiCache) {
        spkiCache = [NSKeyedUnarchiver unarchiveObjectWithData:serializedSpkiCache];
    }
    return spkiCache;
}

- (NSMutableDictionary<NSNumber *, SpkiCacheDictionnary *> *)getSpkiCache
{
    return _subjectPublicKeyInfoHashesCache;
}

#pragma mark Private

- (NSData *)getPublicKeyDataFromCertificate:(SecCertificateRef)certificate
{
#if TARGET_OS_WATCH || TARGET_OS_TV
    // watchOS 3+ or tvOS 10+
    return [self getPublicKeyDataFromCertificate_unified:certificate];
#elif TARGET_OS_IOS
    // iOS 7+
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 100000
    // Base SDK is iOS 7, 8 or 9
    return [self getPublicKeyDataFromCertificate_legacy_ios:certificate ];
#else
    // Base SDK is iOS 10+ - try to use the unified Security APIs if available
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    if ([processInfo respondsToSelector:@selector(isOperatingSystemAtLeastVersion:)] && [processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){10, 0, 0}])
    {
        // iOS 10+
        return [self getPublicKeyDataFromCertificate_unified:certificate];
    }
    else
    {
        // iOS 7, 8, 9
        return [self getPublicKeyDataFromCertificate_legacy_ios:certificate];
    }
#endif
#else
    // macOS 10.9+
#if LEGACY_MACOS_KEY_EXTRACTION
    // Base SDK is macOS 10.9, 10.10 or 10.11
    return [self getPublicKeyDataFromCertificate_legacy_macos:certificate];
#else
    // Base SDK is macOS 10.12 - try to use the unified Security APIs if available
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    if ([processInfo respondsToSelector:@selector(isOperatingSystemAtLeastVersion:)]
        && [processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){10, 12, 0}])
    {
        // macOS 10.12+
        return [self getPublicKeyDataFromCertificate_unified:certificate];
    }
    else
    {
        // macOS 10.9, 10.10, 10.11
        return [self getPublicKeyDataFromCertificate_legacy_macos:certificate];
    }
#endif
#endif
}

@end


#pragma mark Public Key Converter - iOS 10.0+, macOS 10.12+, watchOS 3.0, tvOS 10.0
#if UNIFIED_KEY_EXTRACTION
@implementation TSKSPKIHashCache (Unified)

// Use the unified SecKey API (specifically SecKeyCopyExternalRepresentation())
- (NSData *)getPublicKeyDataFromCertificate_unified:(SecCertificateRef)certificate
{
    SecKeyRef publicKey;
    SecTrustRef tempTrust;
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    
    // Get a public key reference from the certificate
    SecTrustCreateWithCertificates(certificate, policy, &tempTrust);
    SecTrustEvaluate(tempTrust, NULL);
    publicKey = SecTrustCopyPublicKey(tempTrust);
    CFRelease(policy);
    CFRelease(tempTrust);
    
    CFDataRef publicKeyData = SecKeyCopyExternalRepresentation(publicKey, NULL);
    CFRelease(publicKey);
    return (NSData *)CFBridgingRelease(publicKeyData);
}

@end
#endif


#pragma mark Public Key Converter - iOS before 10.0
#if LEGACY_IOS_KEY_EXTRACTION
@implementation TSKSPKIHashCache (LegacyIOS)

- (NSData *)getPublicKeyDataFromCertificate_legacy_ios:(SecCertificateRef)certificate
{
    NSData *publicKeyData = nil;
    __block OSStatus resultAdd, __block resultDel = noErr;
    SecKeyRef publicKey;
    SecTrustRef tempTrust;
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    
    // Get a public key reference from the certificate
    SecTrustCreateWithCertificates(certificate, policy, &tempTrust);
    SecTrustEvaluate(tempTrust, NULL);
    publicKey = SecTrustCopyPublicKey(tempTrust);
    CFRelease(policy);
    CFRelease(tempTrust);
    
    
    // Extract the actual bytes from the key reference using the Keychain
    // Prepare the dictionary to add the key
    NSMutableDictionary *peerPublicKeyAdd = [[NSMutableDictionary alloc] init];
    [peerPublicKeyAdd setObject:(__bridge id)kSecClassKey forKey:(__bridge id)kSecClass];
    [peerPublicKeyAdd setObject:kTSKKeychainPublicKeyTag forKey:(__bridge id)kSecAttrApplicationTag];
    [peerPublicKeyAdd setObject:(__bridge id)(publicKey) forKey:(__bridge id)kSecValueRef];
    
    // Avoid issues with background fetching while the device is locked
    [peerPublicKeyAdd setObject:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly forKey:(__bridge id)kSecAttrAccessible];
    
    // Request the key's data to be returned
    [peerPublicKeyAdd setObject:(__bridge id)(kCFBooleanTrue) forKey:(__bridge id)kSecReturnData];
    
    // Prepare the dictionary to retrieve and delete the key
    NSMutableDictionary * publicKeyGet = [[NSMutableDictionary alloc] init];
    [publicKeyGet setObject:(__bridge id)kSecClassKey forKey:(__bridge id)kSecClass];
    [publicKeyGet setObject:(kTSKKeychainPublicKeyTag) forKey:(__bridge id)kSecAttrApplicationTag];
    [publicKeyGet setObject:(__bridge id)(kCFBooleanTrue) forKey:(__bridge id)kSecReturnData];
    
    
    // Get the key bytes from the Keychain atomically
    dispatch_sync(self.keychainQueue, ^{
        resultAdd = SecItemAdd((__bridge CFDictionaryRef) peerPublicKeyAdd, (void *)&publicKeyData);
        resultDel = SecItemDelete((__bridge CFDictionaryRef)(publicKeyGet));
    });
    
    CFRelease(publicKey);
    if ((resultAdd != errSecSuccess) || (resultDel != errSecSuccess))
    {
        // Something went wrong with the Keychain we won't know if we did get the right key data
        TSKLog(@"Keychain error");
        publicKeyData = nil;
    }
    
    return publicKeyData;
}

@end
#endif


#pragma mark Public Key Converter - macOS before 10.12
#if LEGACY_MACOS_KEY_EXTRACTION
@implementation TSKSPKIHashCache (LegacyMacOS)

// Need to support macOS before 10.12

- (NSData *)getPublicKeyDataFromCertificate_legacy_macos:(SecCertificateRef)certificate
{
    NSData *publicKeyData = nil;
    CFErrorRef error = NULL;
    
    // SecCertificateCopyValues() is macOS only
    NSArray *oids = [NSArray arrayWithObject:(__bridge id)(kSecOIDX509V1SubjectPublicKey)];
    CFDictionaryRef certificateValues = SecCertificateCopyValues(certificate, (__bridge CFArrayRef)(oids), &error);
    if (certificateValues == NULL)
    {
        CFStringRef errorDescription = CFErrorCopyDescription(error);
        TSKLog(@"SecCertificateCopyValues() error: %@", errorDescription);
        CFRelease(errorDescription);
        CFRelease(error);
        return nil;
    }
    
    for (NSString* fieldName in (__bridge NSDictionary *)certificateValues)
    {
        NSDictionary *fieldDict = CFDictionaryGetValue(certificateValues, (__bridge const void *)(fieldName));
        if ([fieldDict[(__bridge __strong id)(kSecPropertyKeyLabel)] isEqualToString:@"Public Key Data"])
        {
            publicKeyData = fieldDict[(__bridge __strong id)(kSecPropertyKeyValue)];
        }
    }
    CFRelease(certificateValues);
    return publicKeyData;
}

@end
#endif

@implementation TSKSPKIHashCache (TestSupport)

- (void)resetSubjectPublicKeyInfoDiskCache {
    // Discard SPKI cache
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *spkiCachePath = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0]
                               stringByAppendingPathComponent:self.spkiCacheFilename];
    [fileManager removeItemAtPath:spkiCachePath error:nil];
}

@end
