#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include <sstream>
#include <string>

#include "Log.h"
#include "MacUtil.h"
#include "Shell.h"

namespace {

std::string Base64ToDer(const std::string &pem) {
  std::string base64;
  std::istringstream stream(pem);
  std::string line;
  while (std::getline(stream, line)) {
    if (line.rfind("-----", 0) == 0) continue;
    base64 += line;
  }

  NSData *data =
      [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:base64.c_str()]
                                          options:0];
  if (!data) return {};
  return std::string((const char *)data.bytes, (size_t)data.length);
}

} // namespace

// Verifies the RSA/SHA-256 (PKCS#1 v1.5) signature of the update manifest with
// the embedded public key. Windows uses OpenSSL for the same operation.
bool VerifyUpdateSignature(const std::string &data, const std::string &signatureBase64) {
  std::string der = Base64ToDer(public_key_pem);
  if (der.empty()) {
    AppendToCrashLog("[UPDATER]: Could not decode embedded public key");
    return false;
  }

  NSData *keyData = [NSData dataWithBytes:der.data() length:der.size()];
  NSDictionary *attributes = @{
    (__bridge id)kSecAttrKeyType : (__bridge id)kSecAttrKeyTypeRSA,
    (__bridge id)kSecAttrKeyClass : (__bridge id)kSecAttrKeyClassPublic,
    (__bridge id)kSecAttrKeySizeInBits : @2048,
  };

  CFErrorRef keyError = nullptr;
  SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)keyData,
                                       (__bridge CFDictionaryRef)attributes, &keyError);
  if (!key) {
    NSError *nsError = keyError ? (__bridge NSError *)keyError : nil;
    std::string message = nsError ? NsToUtf8(nsError.localizedDescription) : "";
    if (keyError) CFRelease(keyError);
    AppendToCrashLog("[UPDATER]: SecKeyCreateWithData failed: " + message);
    return false;
  }

  NSData *signature = [[NSData alloc]
      initWithBase64EncodedString:[NSString stringWithUTF8String:signatureBase64.c_str()]
                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
  NSData *payload = [NSData dataWithBytes:data.data() length:data.size()];

  CFErrorRef verifyError = nullptr;
  bool ok = SecKeyVerifySignature(key, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
                                  (__bridge CFDataRef)payload, (__bridge CFDataRef)signature,
                                  &verifyError) == true;
  if (!ok && verifyError) {
    NSError *nsError = (__bridge NSError *)verifyError;
    AppendToCrashLog("[UPDATER]: Signature invalid: " + NsToUtf8(nsError.localizedDescription));
    CFRelease(verifyError);
  }
  CFRelease(key);
  return ok;
}
