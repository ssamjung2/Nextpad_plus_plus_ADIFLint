// TQSL's callsign certificates, and whether a passphrase unlocks one's private key.
//
// TQSL (tqsllib, sourceforge.net/p/trustedqsl/tqsl, master, read 2026-11-02) keeps its
// certificates in certs/user under its folder (PEM X.509; adif_qsl.h) and each callsign's
// private keys in keys/CALL, a file of ADIF-style fields per key (src/openssl_cert.cpp:
// tqsl_createCertRequest writes PRIVATE_KEY and PUBLIC_KEY, tqsl_find_matching_key matches
// a certificate to the key with its public key). A key with a passphrase is PEM encrypted by
// OpenSSL's PEM_write_bio_PrivateKey with Triple-DES: PKCS#8 with PBES2 from OpenSSL 1.0 on,
// the older "Proc-Type: 4,ENCRYPTED" form before. Checking a passphrase decrypts the key in
// memory, as tqsl_unlock_key does, and confirms it is the certificate's own key; the key is
// wiped and never kept. Only this file reads keys/, and only when a passphrase is checked.
//
// Not in adif_core: it needs CommonCrypto (macOS) for PBKDF2, Triple-DES, AES and MD5.
#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace adif {

struct TqslCertificate {
    std::string call;               // AROcallsign, OID 1.3.6.1.4.1.12348.1.1, upper case
    std::string serial;             // decimal, as TQSL shows it
    int dxcc = 0;                   // dxccEntity, OID ...12348.1.4
    std::string qsoFrom, qsoTo;     // QSONotBeforeDate and QSONotAfterDate (...1.2, ...1.3), YYYY-MM-DD; "" when absent
    std::string validFrom, expires; // the certificate's validity, YYYY-MM-DD (UTC)
    std::string publicKey;          // its SubjectPublicKeyInfo, DER
};

// The callsign certificates in certs/user, in the file's order; a certificate without an
// AROcallsign (TQSL's own CA certificates are kept elsewhere) is left out.
std::vector<TqslCertificate> parseTqslCertificates(std::string_view pem);

// The file in keys/ that holds a callsign's keys: tqsllib's tqsl_clean_call, '_' for
// anything but letters and digits ("KW9D/P" -> "KW9D_P").
std::string tqslKeyFileName(std::string_view call);

enum class TqslKeyCheck : unsigned char {
    Unlocked,      // the passphrase unlocks the certificate's key
    NoPassphrase,  // the key has none, so TQSL asks for none
    Wrong,         // it does not unlock it
    NoKey,         // no key in the file belongs to the certificate: TQSL can sign with it only where it
                   // was requested, or once a .p12 holding it is loaded
    Unreadable,    // the key is there, in a form this code does not read
};

// Whether `passphrase` unlocks the private key, among those in a keys/ file, whose public
// key is `certificatePublicKey` (TqslCertificate::publicKey).
TqslKeyCheck checkTqslPassphrase(std::string_view keyFile, std::string_view certificatePublicKey, std::string_view passphrase);

}  // namespace adif
