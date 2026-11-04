// A TQSL callsign certificate and its key file, made in memory for the tests: never real
// keys, and never written anywhere but a test's own temporary folder.
//
// The RSA key comes from the Security framework, which also encrypts it in the forms tqsllib's
// OpenSSL writes (SecItemExport: PKCS#8 with PBES2, PBKDF2-HMAC-SHA1 and Triple-DES, and the
// traditional "Proc-Type: 4,ENCRYPTED" PEM), so the decoding in adif_tqsl.cpp is checked against
// an encoder it does not share. The certificate is built here as DER, with tqsllib's subject
// attribute and extensions (adif_tqsl.h), and SecCertificateCreateWithData must accept it.
#pragma once

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonKeyDerivation.h>

#include <string>
#include <vector>

namespace tqslfixture {

inline std::string der(unsigned char tag, const std::string &body) {
    std::string out(1, (char)tag);
    size_t n = body.size();
    if (n < 0x80) out += (char)n;
    else if (n < 0x100) out += "\x81", out += (char)n;
    else out += "\x82", out += (char)(n >> 8), out += (char)(n & 0xFF);
    return out + body;
}
inline std::string seq(const std::string &b) { return der(0x30, b); }
inline std::string oid(const char *bytes, size_t n) { return der(0x06, std::string(bytes, n)); }

inline std::string base64(const std::string &d) {
    NSData *data = [NSData dataWithBytes:d.data() length:d.size()];
    return [data base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength | NSDataBase64EncodingEndLineWithLineFeed].UTF8String;
}
inline std::string pem(const char *label, const std::string &d) {
    return std::string("-----BEGIN ") + label + "-----\n" + base64(d) + "\n-----END " + label + "-----\n";
}

const char kRsa[] = "\x2A\x86\x48\x86\xF7\x0D\x01\x01\x01";  // rsaEncryption

struct Key {
    SecKeyRef secKey = nullptr;  // the private key; CFRelease it when done
    std::string spki;   // SubjectPublicKeyInfo, DER
    std::string pkcs1;  // RSAPrivateKey, DER
};

inline Key makeKey() {
    Key k;
    NSDictionary *attrs = @{(id)kSecAttrKeyType : (id)kSecAttrKeyTypeRSA, (id)kSecAttrKeySizeInBits : @1024};
    k.secKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attrs, nullptr);
    SecKeyRef pub = SecKeyCopyPublicKey(k.secKey);
    NSData *pubDer = CFBridgingRelease(SecKeyCopyExternalRepresentation(pub, nullptr));  // RSAPublicKey (PKCS#1)
    NSData *privDer = CFBridgingRelease(SecKeyCopyExternalRepresentation(k.secKey, nullptr));
    CFRelease(pub);
    std::string rsaPub((const char *)pubDer.bytes, pubDer.length);
    k.pkcs1.assign((const char *)privDer.bytes, privDer.length);
    k.spki = seq(seq(oid(kRsa, 9) + std::string("\x05\x00", 2)) + der(0x03, std::string(1, '\0') + rsaPub));
    return k;
}

// A certificate as LoTW issues them: AROcallsign in the subject, QSO dates and DXCC as extensions.
inline std::string certificate(const Key &k, const std::string &call, unsigned serial, const std::string &qsoFrom, const std::string &qsoTo,
                               int dxcc) {
    const char sha256Rsa[] = "\x2A\x86\x48\x86\xF7\x0D\x01\x01\x0B", cn[] = "\x55\x04\x03", aro[] = "\x2B\x06\x01\x04\x01\xE0\x3C\x01\x01";
    std::string alg = seq(oid(sha256Rsa, 9) + std::string("\x05\x00", 2));
    std::string serialBytes;
    for (int s = 24; s >= 0; s -= 8)
        if ((serial >> s) & 0xFF || !serialBytes.empty()) serialBytes += (char)((serial >> s) & 0xFF);
    if (serialBytes.empty() || ((unsigned char)serialBytes[0] & 0x80)) serialBytes.insert(serialBytes.begin(), '\0');
    std::string issuer = seq(der(0x31, seq(oid(cn, 3) + der(0x13, "Test CA"))));
    std::string subject = seq(der(0x31, seq(oid(cn, 3) + der(0x13, "Test Station"))) + der(0x31, seq(oid(aro, 9) + der(0x13, call))));
    std::string validity = seq(der(0x17, "250101000000Z") + der(0x17, "280101000000Z"));
    auto ext = [](char last, const std::string &value) {
        std::string o = std::string("\x2B\x06\x01\x04\x01\xE0\x3C\x01", 8) + last;
        return seq(oid(o.data(), o.size()) + der(0x04, value));
    };
    std::string exts = ext('\x02', qsoFrom) + (qsoTo.empty() ? "" : ext('\x03', qsoTo)) + ext('\x04', std::to_string(dxcc));
    std::string tbs = seq(der(0xA0, der(0x02, std::string(1, '\x02'))) + der(0x02, serialBytes) + alg + issuer + validity + subject + k.spki +
                          der(0xA3, seq(exts)));
    return seq(tbs + alg + der(0x03, std::string(1, '\0') + std::string(128, '\x5A')));  // the signature is not checked
}

// The private key as tqsllib's OpenSSL leaves it: "pkcs8" (PBES2, 3DES), "traditional"
// (DES-EDE3-CBC), "aes" (PBES2 with PBKDF2-HMAC-SHA256 and AES-256, as OpenSSL 3 can write it;
// encoded here, so less independent), or "plain" (no passphrase).
inline std::string privateKeyPem(const Key &k, const char *form, NSString *passphrase) {
    std::string f = form;
    if (f == "aes") {
        std::string info = seq(der(0x02, std::string(1, '\0')) + seq(oid(kRsa, 9) + std::string("\x05\x00", 2)) + der(0x04, k.pkcs1));
        std::string salt = "saltsalt", iv = "0123456789abcdef", key(32, '\0'), pass = passphrase.UTF8String;
        CCKeyDerivationPBKDF(kCCPBKDF2, pass.data(), pass.size(), (const uint8_t *)salt.data(), salt.size(), kCCPRFHmacAlgSHA256, 2048,
                             (uint8_t *)&key[0], key.size());
        std::string out(info.size() + 32, '\0');
        size_t moved = 0;
        CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.data(), key.size(), iv.data(), info.data(), info.size(), &out[0], out.size(), &moved);
        out.resize(moved);
        const char pbes2[] = "\x2A\x86\x48\x86\xF7\x0D\x01\x05\x0D", pbkdf2[] = "\x2A\x86\x48\x86\xF7\x0D\x01\x05\x0C",
                   sha256[] = "\x2A\x86\x48\x86\xF7\x0D\x02\x09", aes256[] = "\x60\x86\x48\x01\x65\x03\x04\x01\x2A";
        std::string kdf = seq(oid(pbkdf2, 9) + seq(der(0x04, salt) + der(0x02, std::string("\x08\x00", 2)) + seq(oid(sha256, 8) + std::string("\x05\x00", 2))));
        std::string scheme = seq(oid(aes256, 9) + der(0x04, iv));
        return pem("ENCRYPTED PRIVATE KEY", seq(seq(oid(pbes2, 9) + seq(kdf + scheme)) + der(0x04, out)));
    }
    SecItemImportExportKeyParameters p = {};
    p.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
    p.passphrase = (__bridge CFStringRef)passphrase;
    CFDataRef out = nullptr;
    SecExternalFormat format = f == "pkcs8" ? kSecFormatWrappedPKCS8 : f == "traditional" ? kSecFormatWrappedOpenSSL : kSecFormatOpenSSL;
    if (SecItemExport(k.secKey, format, kSecItemPemArmour, f == "plain" ? nullptr : &p, &out) != errSecSuccess || !out) return "";
    NSData *data = CFBridgingRelease(out);
    return std::string((const char *)data.bytes, data.length);
}

// keys/CALL as tqsllib writes it: <NAME:LENGTH>data fields, a blank line after each, <eor> after each key.
inline std::string keyRecord(const Key &k, const std::string &call, const std::string &privatePem, bool deleted = false) {
    auto field = [](const char *name, const std::string &v) { return "<" + std::string(name) + ":" + std::to_string(v.size()) + ">" + v + "\n\n"; };
    std::string r = field("TQSL_CRQ_PROVIDER", "ARRL") + field("CALLSIGN", call) + field("PRIVATE_KEY", privatePem) + field("PUBLIC_KEY", pem("PUBLIC KEY", k.spki));
    if (deleted) r += field("DELETED", "True");
    return r + "<eor>\n\n";
}

}  // namespace tqslfixture
