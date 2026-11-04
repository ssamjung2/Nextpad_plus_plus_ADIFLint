// Tests for TQSL's certificates and the passphrase check (adif_tqsl.h), with keys and
// certificates made in memory (tqsl_fixture.h).
#include "adif_tqsl.h"
#include "tqsl_fixture.h"

#include <cstdio>
#include <random>
#include <string>

using namespace adif;
using namespace tqslfixture;

static int gFailures = 0, gChecks = 0;

#define CHECK(cond, ...)                                    \
    do {                                                    \
        ++gChecks;                                          \
        if (!(cond)) {                                      \
            ++gFailures;                                    \
            std::printf("FAIL %s:%d: ", __FILE__, __LINE__); \
            std::printf(__VA_ARGS__);                       \
            std::printf("\n");                              \
        }                                                   \
    } while (0)

static const char *name(TqslKeyCheck c) {
    switch (c) {
        case TqslKeyCheck::Unlocked: return "unlocked";
        case TqslKeyCheck::NoPassphrase: return "no passphrase";
        case TqslKeyCheck::Wrong: return "wrong";
        case TqslKeyCheck::NoKey: return "no key";
        case TqslKeyCheck::Unreadable: return "unreadable";
    }
    return "?";
}

static void testCertificates() {
    Key a = makeKey(), b = makeKey();
    std::string certA = certificate(a, "KW9D", 1234567, "2010-01-01", "", 291), certB = certificate(b, "KW9D/P", 200, "2020-06-01", "2030-12-31", 291);
    // Apple's X.509 parser takes them: they are certificates, not something only this code reads.
    for (const std::string *c : {&certA, &certB}) {
        SecCertificateRef sc = SecCertificateCreateWithData(nullptr, (__bridge CFDataRef)[NSData dataWithBytes:c->data() length:c->size()]);
        CHECK(sc != nullptr, "SecCertificateCreateWithData accepts the test certificate");
        if (sc) CFRelease(sc);
    }
    std::string user = pem("CERTIFICATE", certA) + pem("CERTIFICATE", certB);
    std::vector<TqslCertificate> certs = parseTqslCertificates(user);
    CHECK(certs.size() == 2, "two certificates: %zu", certs.size());
    if (certs.size() == 2) {
        const TqslCertificate &c = certs[0];
        CHECK(c.call == "KW9D" && c.serial == "1234567" && c.dxcc == 291 && c.qsoFrom == "2010-01-01" && c.qsoTo.empty() && c.validFrom == "2025-01-01" &&
                  c.expires == "2028-01-01" && c.publicKey == a.spki,
              "KW9D: %s serial %s dxcc %d QSOs %s to %s, valid %s to %s", c.call.c_str(), c.serial.c_str(), c.dxcc, c.qsoFrom.c_str(), c.qsoTo.c_str(),
              c.validFrom.c_str(), c.expires.c_str());
        CHECK(certs[1].call == "KW9D/P" && certs[1].serial == "200" && certs[1].qsoTo == "2030-12-31", "KW9D/P");
    }
    // A CA certificate (no AROcallsign) and garbage are left out.
    std::string ca = seq(seq(der(0xA0, der(0x02, "\x02")) + der(0x02, "\x01")));
    CHECK(parseTqslCertificates(pem("CERTIFICATE", ca) + "-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n").empty(), "no callsign, no certificate");
    CHECK(tqslKeyFileName("KW9D/P") == "KW9D_P" && tqslKeyFileName("VE3/KW9D") == "VE3_KW9D", "key file names (tqsl_clean_call)");
}

static void testPassphrases() {
    NSString *pass = @"correct horse 9";
    Key k = makeKey(), other = makeKey();
    for (const char *form : {"pkcs8", "traditional", "aes"}) {
        std::string priv = privateKeyPem(k, form, pass);
        CHECK(!priv.empty(), "%s: the key exported", form);
        std::string file = keyRecord(other, "KW9D", privateKeyPem(other, "pkcs8", @"another")) + keyRecord(k, "KW9D", priv);
        TqslKeyCheck right = checkTqslPassphrase(file, k.spki, pass.UTF8String);
        CHECK(right == TqslKeyCheck::Unlocked, "%s: the passphrase unlocks it: %s", form, name(right));
        for (const char *wrong : {"", "correct horse", "correct horse 9 ", "Correct horse 9"}) {
            TqslKeyCheck w = checkTqslPassphrase(file, k.spki, wrong);
            CHECK(w == TqslKeyCheck::Wrong, "%s: '%s' does not: %s", form, wrong, name(w));
        }
        // The other key in the file has its own passphrase.
        CHECK(checkTqslPassphrase(file, other.spki, "another") == TqslKeyCheck::Unlocked, "%s: the other key, with its own", form);
    }
    // No false "unlocked" among many wrong passphrases (padding alone would pass 1 in 256).
    std::string file = keyRecord(k, "KW9D", privateKeyPem(k, "pkcs8", pass));
    std::mt19937 rng(7);
    int unlocked = 0;
    for (int i = 0; i < 600; ++i) unlocked += checkTqslPassphrase(file, k.spki, std::to_string(rng())) == TqslKeyCheck::Unlocked;
    CHECK(unlocked == 0, "600 wrong passphrases: %d taken", unlocked);

    // Without a passphrase TQSL asks for none.
    std::string plain = keyRecord(k, "KW9D", privateKeyPem(k, "plain", nil));
    CHECK(plain.find("BEGIN RSA PRIVATE KEY") != std::string::npos && plain.find("ENCRYPTED") == std::string::npos, "a key without a passphrase");
    CHECK(checkTqslPassphrase(plain, k.spki, "") == TqslKeyCheck::NoPassphrase && checkTqslPassphrase(plain, k.spki, "anything") == TqslKeyCheck::NoPassphrase,
          "no passphrase needed");
    // Not this certificate's key: another computer's request, or no file at all.
    CHECK(checkTqslPassphrase(keyRecord(other, "KW9D", privateKeyPem(other, "pkcs8", pass)), k.spki, pass.UTF8String) == TqslKeyCheck::NoKey &&
              checkTqslPassphrase("", k.spki, "x") == TqslKeyCheck::NoKey,
          "no key for the certificate");
    // A key TQSL marked deleted is still tried, last.
    CHECK(checkTqslPassphrase(keyRecord(k, "KW9D", privateKeyPem(k, "traditional", pass), true), k.spki, pass.UTF8String) == TqslKeyCheck::Unlocked,
          "a deleted key, as the last resort");
    // The public key matches but the private key is not one this code reads.
    std::string odd = keyRecord(k, "KW9D", "-----BEGIN DSA PRIVATE KEY-----\nAAAA\n-----END DSA PRIVATE KEY-----\n");
    CHECK(checkTqslPassphrase(odd, k.spki, "x") == TqslKeyCheck::Unreadable, "an unknown key form");
    CHECK(checkTqslPassphrase(file, "not a key", "x") == TqslKeyCheck::Unreadable, "a certificate without an RSA key");

    // Mutated key files: an answer every time, never a crash, and never "unlocked" with a wrong passphrase.
    std::string base = keyRecord(k, "KW9D", privateKeyPem(k, "pkcs8", pass)) + keyRecord(k, "KW9D", privateKeyPem(k, "traditional", pass));
    int bad = 0;
    for (int i = 0; i < 3000; ++i) {
        std::string t = base;
        for (int e = 0; e < 1 + (int)(rng() % 6); ++e) {
            size_t at = rng() % t.size();
            switch (rng() % 3) {
                case 0: t[at] = (char)rng(); break;
                case 1: t.erase(at, 1 + rng() % 40); break;
                case 2: t.insert(at, 1, "<>:0123456789=\n-"[rng() % 16]); break;
            }
            if (t.empty()) t = "<";
        }
        bad += checkTqslPassphrase(t, k.spki, "wrong") == TqslKeyCheck::Unlocked;
    }
    CHECK(bad == 0, "mutated key files: %d unlocked with a wrong passphrase", bad);
    CFRelease(k.secKey);
    CFRelease(other.secKey);
}

int main() {
    @autoreleasepool {
        testCertificates();
        testPassphrases();
    }
    std::printf("%d/%d checks passed\n", gChecks - gFailures, gChecks);
    return gFailures ? 1 : 0;
}
