// TQSL's certificates and keys (adif_tqsl.h). The formats are standard: X.509 (RFC 5280),
// PKCS#8 with PBES2 and PBKDF2 (RFC 8018), PKCS#1 RSA keys (RFC 8017), and OpenSSL's
// traditional PEM encryption (EVP_BytesToKey with MD5, one round), as tqsllib's OpenSSL writes them.
#include "adif_tqsl.h"

#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonKeyDerivation.h>

#include <algorithm>
#include <cctype>
#include <cstring>

namespace adif {
namespace {

constexpr size_t npos = std::string_view::npos;

// Key material is overwritten before its memory is freed.
void wipe(std::string &s) {
    volatile char *p = s.empty() ? nullptr : &s[0];
    for (size_t i = 0; i < s.size(); ++i) p[i] = 0;
    s.clear();
}

// RFC 4648 base64, skipping white space.
std::string fromBase64(std::string_view s) {
    std::string out;
    unsigned buf = 0;
    int bits = 0;
    for (char c : s) {
        int v = c >= 'A' && c <= 'Z' ? c - 'A' : c >= 'a' && c <= 'z' ? c - 'a' + 26 : c >= '0' && c <= '9' ? c - '0' + 52 : c == '+' ? 62 : c == '/' ? 63 : -1;
        if (v < 0) continue;  // white space, '=' padding
        buf = (buf << 6) | (unsigned)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out += (char)((buf >> bits) & 0xFF);
        }
    }
    return out;
}

// ── DER ──

struct Tlv {
    unsigned char tag = 0;
    std::string_view body;  // the content
    std::string_view all;   // tag, length and content
};

// The element at the start of `d`, and in *rest what follows it. Definite lengths only, as DER has.
bool readTlv(std::string_view d, Tlv *t, std::string_view *rest = nullptr) {
    if (d.size() < 2 || ((unsigned char)d[0] & 0x1F) == 0x1F) return false;
    size_t len = (unsigned char)d[1], h = 2;
    if (len & 0x80) {
        size_t k = len & 0x7F;
        if (k == 0 || k > 4 || d.size() < 2 + k) return false;
        len = 0;
        for (size_t i = 0; i < k; ++i) len = (len << 8) | (unsigned char)d[2 + i];
        h = 2 + k;
    }
    if (len > d.size() - h) return false;
    t->tag = (unsigned char)d[0];
    t->body = d.substr(h, len);
    t->all = d.substr(0, h + len);
    if (rest) *rest = d.substr(h + len);
    return true;
}

// The elements of a SEQUENCE's or SET's content; empty when any is malformed.
std::vector<Tlv> children(std::string_view body) {
    std::vector<Tlv> out;
    Tlv t;
    while (!body.empty()) {
        if (!readTlv(body, &t, &body)) return {};
        out.push_back(t);
    }
    return out;
}

constexpr unsigned char kSequence = 0x30, kSet = 0x31, kInteger = 0x02, kBitString = 0x03, kOctetString = 0x04, kOid = 0x06;

// Object identifiers, as their DER content.
const std::string_view kOidCall("\x2B\x06\x01\x04\x01\xE0\x3C\x01\x01", 9);      // 1.3.6.1.4.1.12348.1.1 AROcallsign
const std::string_view kOidQsoFrom("\x2B\x06\x01\x04\x01\xE0\x3C\x01\x02", 9);   // ...1.2 QSONotBeforeDate
const std::string_view kOidQsoTo("\x2B\x06\x01\x04\x01\xE0\x3C\x01\x03", 9);     // ...1.3 QSONotAfterDate
const std::string_view kOidDxcc("\x2B\x06\x01\x04\x01\xE0\x3C\x01\x04", 9);      // ...1.4 dxccEntity
const std::string_view kOidPbes2("\x2A\x86\x48\x86\xF7\x0D\x01\x05\x0D", 9);     // 1.2.840.113549.1.5.13
const std::string_view kOidPbkdf2("\x2A\x86\x48\x86\xF7\x0D\x01\x05\x0C", 9);    // 1.2.840.113549.1.5.12
const std::string_view kOidDes3Cbc("\x2A\x86\x48\x86\xF7\x0D\x03\x07", 8);       // 1.2.840.113549.3.7
const std::string_view kOidAesCbc("\x60\x86\x48\x01\x65\x03\x04\x01", 8);        // 2.16.840.1.101.3.4.1, then 2, 22 or 42
const std::string_view kOidHmac("\x2A\x86\x48\x86\xF7\x0D\x02", 7);              // 1.2.840.113549.2, then 7 (SHA-1) to 11

// An unsigned big-endian integer in decimal.
std::string decimal(std::string_view bytes) {
    std::vector<unsigned char> n(bytes.begin(), bytes.end());
    std::string digits;
    while (!n.empty()) {
        unsigned rem = 0;
        std::vector<unsigned char> q;
        for (unsigned char b : n) {
            unsigned cur = (rem << 8) | b;
            unsigned char d = (unsigned char)(cur / 10);
            rem = cur % 10;
            if (!q.empty() || d) q.push_back(d);
        }
        digits += (char)('0' + rem);
        n.swap(q);
    }
    if (digits.empty()) digits = "0";
    std::reverse(digits.begin(), digits.end());
    return digits;
}

// UTCTime or GeneralizedTime as YYYY-MM-DD.
std::string dateOf(const Tlv &t) {
    std::string_view s = t.body;
    std::string y;
    if (t.tag == 0x17 && s.size() >= 6) {  // YYMMDD...: 50-99 are 1950-1999 (RFC 5280, 4.1.2.5.1)
        y = (s[0] >= '5' ? "19" : "20") + std::string(s.substr(0, 2));
        s.remove_prefix(2);
    } else if (t.tag == 0x18 && s.size() >= 8) {
        y = std::string(s.substr(0, 4));
        s.remove_prefix(4);
    } else {
        return "";
    }
    return y + "-" + std::string(s.substr(0, 2)) + "-" + std::string(s.substr(2, 2));
}

// An INTEGER's value without the sign byte DER adds before a high bit.
std::string_view magnitude(std::string_view v) {
    while (v.size() > 1 && v[0] == 0) v.remove_prefix(1);
    return v;
}

// The RSA modulus of a SubjectPublicKeyInfo, an RSAPrivateKey (PKCS#1) or a PrivateKeyInfo (PKCS#8).
std::string_view publicModulus(std::string_view spki) {
    Tlv t;
    if (!readTlv(spki, &t) || t.tag != kSequence) return {};
    std::vector<Tlv> parts = children(t.body);
    if (parts.size() != 2 || parts[1].tag != kBitString || parts[1].body.empty() || parts[1].body[0] != 0) return {};
    if (!readTlv(parts[1].body.substr(1), &t) || t.tag != kSequence) return {};
    std::vector<Tlv> key = children(t.body);
    return key.size() == 2 && key[0].tag == kInteger ? magnitude(key[0].body) : std::string_view();
}

std::string_view privateModulus(std::string_view der) {
    Tlv t;
    if (!readTlv(der, &t) || t.tag != kSequence) return {};
    std::vector<Tlv> parts = children(t.body);
    if (parts.size() >= 3 && parts[0].tag == kInteger && parts[1].tag == kSequence && parts[2].tag == kOctetString)
        return privateModulus(parts[2].body);  // PKCS#8: version, algorithm, the key
    return parts.size() >= 9 && parts[0].tag == kInteger && parts[1].tag == kInteger ? magnitude(parts[1].body) : std::string_view();
}

// ── PEM ──

struct Pem {
    std::string label;  // "ENCRYPTED PRIVATE KEY"...
    std::string procType, dekInfo;
    std::string der;
};

bool parsePem(std::string_view text, Pem *out) {
    size_t b = text.find("-----BEGIN ");
    if (b == npos) return false;
    size_t le = text.find("-----", b + 11);
    if (le == npos) return false;
    out->label = std::string(text.substr(b + 11, le - b - 11));
    std::string endLine = "-----END " + out->label + "-----";
    size_t body = text.find('\n', le);
    size_t e = text.find(endLine, le);
    if (body == npos || e == npos || e < body) return false;
    std::string_view inner = text.substr(body + 1, e - body - 1);
    // RFC 1421 headers, then a blank line, then the base64.
    if (inner.find("Proc-Type:") != npos) {
        size_t blank = inner.find("\n\n");
        if (blank == npos) blank = inner.find("\r\n\r\n");
        std::string_view headers = inner.substr(0, blank == npos ? 0 : blank);
        auto header = [&](std::string_view name) {
            size_t at = headers.find(name);
            if (at == npos) return std::string();
            size_t from = at + name.size(), to = headers.find('\n', from);
            std::string v(headers.substr(from, to == npos ? npos : to - from));
            v.erase(0, v.find_first_not_of(" \t"));
            while (!v.empty() && (v.back() == '\r' || v.back() == ' ')) v.pop_back();
            return v;
        };
        out->procType = header("Proc-Type:");
        out->dekInfo = header("DEK-Info:");
        inner = blank == npos ? std::string_view() : inner.substr(blank);
    }
    out->der = fromBase64(inner);
    return true;
}

// ── Decryption ──

enum class Decrypted { Ok, Wrong, Unsupported };

// CBC decryption with PKCS#7 padding; a wrong key almost always leaves bad padding.
Decrypted decryptCbc(CCAlgorithm alg, const std::string &key, std::string_view iv, std::string_view data, std::string *plain) {
    size_t block = alg == kCCAlgorithmAES ? kCCBlockSizeAES128 : kCCBlockSize3DES;
    if (iv.size() != block || data.empty() || data.size() % block) return Decrypted::Unsupported;
    plain->assign(data.size() + block, '\0');
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, alg, kCCOptionPKCS7Padding, key.data(), key.size(), iv.data(), data.data(), data.size(), &(*plain)[0],
                                 plain->size(), &moved);
    if (st != kCCSuccess) {
        wipe(*plain);
        return Decrypted::Wrong;
    }
    plain->resize(moved);
    return Decrypted::Ok;
}

// PKCS#8 EncryptedPrivateKeyInfo with PBES2 and PBKDF2 (RFC 8018, A.2 and A.4).
Decrypted decryptPbes2(std::string_view der, std::string_view passphrase, std::string *plain) {
    Tlv t;
    if (!readTlv(der, &t) || t.tag != kSequence) return Decrypted::Unsupported;
    std::vector<Tlv> info = children(t.body);  // algorithm, encryptedData
    if (info.size() != 2 || info[1].tag != kOctetString) return Decrypted::Unsupported;
    std::vector<Tlv> alg = children(info[0].body);  // pbes2, parameters
    if (alg.size() != 2 || alg[0].tag != kOid || alg[0].body != kOidPbes2) return Decrypted::Unsupported;
    std::vector<Tlv> params = children(alg[1].body);  // keyDerivationFunc, encryptionScheme
    if (params.size() != 2) return Decrypted::Unsupported;
    std::vector<Tlv> kdf = children(params[0].body), scheme = children(params[1].body);
    if (kdf.size() != 2 || kdf[0].body != kOidPbkdf2 || scheme.size() != 2 || scheme[1].tag != kOctetString) return Decrypted::Unsupported;
    std::vector<Tlv> pbkdf2 = children(kdf[1].body);  // salt, iterationCount, [keyLength], [prf]
    if (pbkdf2.size() < 2 || pbkdf2[0].tag != kOctetString || pbkdf2[1].tag != kInteger || pbkdf2[1].body.size() > 4) return Decrypted::Unsupported;
    unsigned rounds = 0;
    for (unsigned char c : pbkdf2[1].body) rounds = (rounds << 8) | c;
    if (rounds == 0 || rounds > 10000000) return Decrypted::Unsupported;  // a file that would stall the check
    CCPseudoRandomAlgorithm prf = kCCPRFHmacAlgSHA1;  // the default
    for (size_t i = 2; i < pbkdf2.size(); ++i) {
        if (pbkdf2[i].tag != kSequence) continue;
        std::vector<Tlv> p = children(pbkdf2[i].body);
        if (p.empty() || p[0].body.size() != kOidHmac.size() + 1 || p[0].body.substr(0, kOidHmac.size()) != kOidHmac) return Decrypted::Unsupported;
        switch ((unsigned char)p[0].body.back()) {
            case 7: prf = kCCPRFHmacAlgSHA1; break;
            case 8: prf = kCCPRFHmacAlgSHA224; break;
            case 9: prf = kCCPRFHmacAlgSHA256; break;
            case 10: prf = kCCPRFHmacAlgSHA384; break;
            case 11: prf = kCCPRFHmacAlgSHA512; break;
            default: return Decrypted::Unsupported;
        }
    }
    CCAlgorithm cipher;
    size_t keyLength;
    std::string_view oid = scheme[0].body;
    if (oid == kOidDes3Cbc) cipher = kCCAlgorithm3DES, keyLength = kCCKeySize3DES;
    else if (oid.size() == kOidAesCbc.size() + 1 && oid.substr(0, kOidAesCbc.size()) == kOidAesCbc && (oid.back() == 2 || oid.back() == 22 || oid.back() == 42))
        cipher = kCCAlgorithmAES, keyLength = oid.back() == 2 ? kCCKeySizeAES128 : oid.back() == 22 ? kCCKeySizeAES192 : kCCKeySizeAES256;
    else return Decrypted::Unsupported;
    std::string key(keyLength, '\0');
    std::string_view salt = pbkdf2[0].body;
    if (CCKeyDerivationPBKDF(kCCPBKDF2, passphrase.data(), passphrase.size(), (const uint8_t *)salt.data(), salt.size(), prf, rounds,
                             (uint8_t *)&key[0], key.size()) != kCCSuccess)
        return Decrypted::Unsupported;
    Decrypted d = decryptCbc(cipher, key, scheme[1].body, info[1].body, plain);
    wipe(key);
    return d;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"  // MD5: the old PEM format's key derivation, not a hash to trust
// OpenSSL's EVP_BytesToKey with MD5 and one round: the key of "Proc-Type: 4,ENCRYPTED" PEM.
std::string bytesToKey(std::string_view passphrase, std::string_view salt, size_t length) {
    std::string out, prev;
    while (out.size() < length) {
        CC_MD5_CTX c;
        CC_MD5_Init(&c);
        CC_MD5_Update(&c, prev.data(), (CC_LONG)prev.size());
        CC_MD5_Update(&c, passphrase.data(), (CC_LONG)passphrase.size());
        CC_MD5_Update(&c, salt.data(), (CC_LONG)salt.size());
        unsigned char digest[CC_MD5_DIGEST_LENGTH];
        CC_MD5_Final(digest, &c);
        prev.assign((const char *)digest, sizeof digest);
        out += prev;
        memset(digest, 0, sizeof digest);
    }
    wipe(prev);
    out.resize(length);
    return out;
}
#pragma clang diagnostic pop

// "DEK-Info: DES-EDE3-CBC,0123456789ABCDEF" (RFC 1421, as OpenSSL writes it).
Decrypted decryptTraditional(const Pem &pem, std::string_view passphrase, std::string *plain) {
    size_t comma = pem.dekInfo.find(',');
    if (comma == npos) return Decrypted::Unsupported;
    std::string name = pem.dekInfo.substr(0, comma), hex = pem.dekInfo.substr(comma + 1);
    CCAlgorithm cipher;
    size_t keyLength;
    if (name == "DES-EDE3-CBC") cipher = kCCAlgorithm3DES, keyLength = kCCKeySize3DES;
    else if (name == "AES-128-CBC") cipher = kCCAlgorithmAES, keyLength = kCCKeySizeAES128;
    else if (name == "AES-192-CBC") cipher = kCCAlgorithmAES, keyLength = kCCKeySizeAES192;
    else if (name == "AES-256-CBC") cipher = kCCAlgorithmAES, keyLength = kCCKeySizeAES256;
    else return Decrypted::Unsupported;
    std::string iv;
    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        if (!std::isxdigit((unsigned char)hex[i]) || !std::isxdigit((unsigned char)hex[i + 1])) return Decrypted::Unsupported;
        iv += (char)std::stoi(hex.substr(i, 2), nullptr, 16);
    }
    if (iv.size() < 8) return Decrypted::Unsupported;
    std::string key = bytesToKey(passphrase, std::string_view(iv).substr(0, 8), keyLength);
    Decrypted d = decryptCbc(cipher, key, iv, pem.der, plain);
    wipe(key);
    return d;
}

// One key file record: <NAME:LENGTH>data, up to <eor> (tqsllib's tqsl_write_adif_field).
struct KeyRecord {
    std::string publicKey, privateKey;
    bool deleted = false;
};

std::vector<KeyRecord> parseKeyFile(std::string_view f) {
    std::vector<KeyRecord> out;
    KeyRecord cur;
    size_t i = 0;
    while ((i = f.find('<', i)) != npos) {
        size_t close = f.find('>', i);
        if (close == npos) break;
        std::string tag(f.substr(i + 1, close - i - 1));
        size_t colon = tag.find(':');
        std::string name = tag.substr(0, colon);
        for (char &c : name) c = (char)std::toupper((unsigned char)c);
        size_t len = 0;
        if (colon != std::string::npos) {
            for (size_t k = colon + 1; k < tag.size() && std::isdigit((unsigned char)tag[k]) && len < (1u << 24); ++k) len = len * 10 + (size_t)(tag[k] - '0');
        }
        std::string value(f.substr(close + 1, std::min(len, f.size() - close - 1)));
        if (name == "EOR") {
            out.push_back(cur);
            wipe(cur.privateKey);
            cur = KeyRecord{};
        } else if (name == "PUBLIC_KEY") {
            cur.publicKey = value;
        } else if (name == "PRIVATE_KEY") {
            cur.privateKey = value;
        } else if (name == "DELETED") {
            cur.deleted = value == "True";
        }
        wipe(value);
        i = close + 1 + len;
    }
    if (!cur.publicKey.empty()) out.push_back(cur);
    wipe(cur.privateKey);
    return out;
}

TqslKeyCheck unlock(const std::string &privatePem, std::string_view passphrase, std::string_view modulus) {
    Pem pem;
    if (!parsePem(privatePem, &pem)) return TqslKeyCheck::Unreadable;
    std::string plain;
    Decrypted d;
    if (pem.label == "ENCRYPTED PRIVATE KEY") {
        d = decryptPbes2(pem.der, passphrase, &plain);
    } else if ((pem.label == "RSA PRIVATE KEY" || pem.label == "PRIVATE KEY") && pem.procType.find("ENCRYPTED") != std::string::npos) {
        d = decryptTraditional(pem, passphrase, &plain);
    } else if (pem.label == "RSA PRIVATE KEY" || pem.label == "PRIVATE KEY") {
        bool ours = privateModulus(pem.der) == modulus;
        wipe(pem.der);
        return ours ? TqslKeyCheck::NoPassphrase : TqslKeyCheck::Unreadable;
    } else {
        return TqslKeyCheck::Unreadable;
    }
    wipe(pem.der);
    TqslKeyCheck result = d == Decrypted::Unsupported ? TqslKeyCheck::Unreadable
                          : d == Decrypted::Wrong     ? TqslKeyCheck::Wrong
                          // Decrypted: the key, if its modulus is the certificate's; else the passphrase made garbage.
                          : privateModulus(plain) == modulus ? TqslKeyCheck::Unlocked
                                                             : TqslKeyCheck::Wrong;
    wipe(plain);
    return result;
}

}  // namespace

std::vector<TqslCertificate> parseTqslCertificates(std::string_view pem) {
    std::vector<TqslCertificate> out;
    const std::string_view begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----";
    for (size_t at = pem.find(begin); at != npos; at = pem.find(begin, at + begin.size())) {
        size_t from = at + begin.size(), to = pem.find(end, from);
        if (to == npos) break;
        std::string der = fromBase64(pem.substr(from, to - from));
        Tlv cert, tbs;
        if (!readTlv(der, &cert) || cert.tag != kSequence || !readTlv(cert.body, &tbs) || tbs.tag != kSequence) continue;
        std::vector<Tlv> f = children(tbs.body);
        size_t i = !f.empty() && f[0].tag == 0xA0 ? 1 : 0;  // [0] version
        if (f.size() < i + 6 || f[i].tag != kInteger) continue;
        TqslCertificate c;
        c.serial = decimal(magnitude(f[i].body));
        std::vector<Tlv> validity = children(f[i + 3].body);
        if (validity.size() == 2) c.validFrom = dateOf(validity[0]), c.expires = dateOf(validity[1]);
        for (const Tlv &rdn : children(f[i + 4].body)) {  // subject: SETs of type and value
            if (rdn.tag != kSet) continue;
            for (const Tlv &atv : children(rdn.body)) {
                std::vector<Tlv> tv = children(atv.body);
                if (tv.size() == 2 && tv[0].tag == kOid && tv[0].body == kOidCall)
                    for (char ch : tv[1].body) c.call += (char)std::toupper((unsigned char)ch);
            }
        }
        c.publicKey = std::string(f[i + 5].all);
        for (size_t k = i + 6; k < f.size(); ++k) {
            if (f[k].tag != 0xA3) continue;  // [3] extensions
            Tlv seq;
            if (!readTlv(f[k].body, &seq)) continue;
            for (const Tlv &ext : children(seq.body)) {
                std::vector<Tlv> e = children(ext.body);  // extnID, [critical], extnValue
                if (e.size() < 2 || e[0].tag != kOid || e.back().tag != kOctetString) continue;
                std::string value(e.back().body);  // tqsllib stores the text itself (tqsl_get_cert_ext)
                if (e[0].body == kOidQsoFrom) c.qsoFrom = value;
                else if (e[0].body == kOidQsoTo) c.qsoTo = value;
                else if (e[0].body == kOidDxcc) c.dxcc = std::atoi(value.c_str());
            }
        }
        if (!c.call.empty()) out.push_back(std::move(c));
    }
    return out;
}

std::string tqslKeyFileName(std::string_view call) {
    std::string out(call);
    for (char &c : out)
        if (!std::isalnum((unsigned char)c)) c = '_';
    return out;
}

TqslKeyCheck checkTqslPassphrase(std::string_view keyFile, std::string_view certificatePublicKey, std::string_view passphrase) {
    std::string_view modulus = publicModulus(certificatePublicKey);
    if (modulus.empty()) return TqslKeyCheck::Unreadable;
    std::vector<KeyRecord> keys = parseKeyFile(keyFile);
    TqslKeyCheck result = TqslKeyCheck::NoKey;
    // A key TQSL marked deleted is its last resort too (tqsl_find_matching_key); the others first.
    for (int pass = 0; pass < 2 && result == TqslKeyCheck::NoKey; ++pass) {
        for (KeyRecord &k : keys) {
            if (k.deleted != (pass == 1)) continue;
            Pem pub;
            if (!parsePem(k.publicKey, &pub) || publicModulus(pub.der) != modulus) continue;
            result = unlock(k.privateKey, passphrase, modulus);
            break;
        }
    }
    for (KeyRecord &k : keys) wipe(k.privateKey);
    return result;
}

}  // namespace adif
