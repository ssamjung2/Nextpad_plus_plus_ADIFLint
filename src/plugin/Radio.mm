#import "Radio.h"

#include "adif_radio.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <functional>

NSString *ADIFRadioKindName(ADIFRadioKind kind) {
    switch (kind) {
        case ADIFRadioRigctld: return @"Hamlib rigctld";
        case ADIFRadioFlrig: return @"flrig";
        default: return @"None";
    }
}

int ADIFRadioDefaultPort(ADIFRadioKind kind) { return kind == ADIFRadioFlrig ? 12345 : 4532; }

ADIFRadioKind ADIFRadioKindFromSetting(const std::string &value) {
    if (value == "rigctld") return ADIFRadioRigctld;
    if (value == "flrig") return ADIFRadioFlrig;
    return ADIFRadioNone;
}

std::string ADIFRadioKindSetting(ADIFRadioKind kind) {
    return kind == ADIFRadioRigctld ? "rigctld" : kind == ADIFRadioFlrig ? "flrig" : "";
}

namespace {

const double kConnectSeconds = 1.5, kReplySeconds = 2.5;
const size_t kMaxReply = 64 * 1024;

double now() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

class Socket {
public:
    ~Socket() {
        if (fd_ >= 0) close(fd_);
    }

    // Connect with a timeout; false with `error` set.
    bool open(const std::string &host, int port, std::string *error) {
        struct addrinfo hints {};
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        struct addrinfo *res = nullptr;
        int rc = getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &res);
        if (rc != 0 || !res) {
            *error = "cannot find " + host;
            return false;
        }
        *error = "nothing is listening on " + host + ":" + std::to_string(port);
        for (struct addrinfo *a = res; a; a = a->ai_next) {
            int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
            if (fd < 0) continue;
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
            int flags = fcntl(fd, F_GETFL, 0);
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            bool ok = connect(fd, a->ai_addr, a->ai_addrlen) == 0;
            if (!ok && errno == EINPROGRESS) {
                struct pollfd p {fd, POLLOUT, 0};
                if (poll(&p, 1, (int)(kConnectSeconds * 1000)) == 1) {
                    int err = 0;
                    socklen_t len = sizeof err;
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
                    ok = err == 0;
                } else {
                    *error = "no answer from " + host + ":" + std::to_string(port);
                }
            }
            if (ok) {
                fd_ = fd;
                break;
            }
            close(fd);
        }
        freeaddrinfo(res);
        return fd_ >= 0;
    }

    bool send(const std::string &data) {
        size_t sent = 0;
        double deadline = now() + kReplySeconds;
        while (sent < data.size()) {
            ssize_t n = ::send(fd_, data.data() + sent, data.size() - sent, 0);
            if (n > 0) {
                sent += (size_t)n;
                continue;
            }
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                struct pollfd p {fd_, POLLOUT, 0};
                double left = deadline - now();
                if (left <= 0 || poll(&p, 1, (int)(left * 1000)) != 1) return false;
                continue;
            }
            return false;
        }
        return true;
    }

    // Read until `complete(buffer)`, the peer closes, or the time runs out.
    bool readUntil(std::string *buffer, const std::function<bool(const std::string &)> &complete) {
        double deadline = now() + kReplySeconds;
        char chunk[4096];
        while (!complete(*buffer)) {
            double left = deadline - now();
            struct pollfd p {fd_, POLLIN, 0};
            if (left <= 0 || poll(&p, 1, (int)(left * 1000)) != 1) return false;
            ssize_t n = recv(fd_, chunk, sizeof chunk, 0);
            if (n == 0) return complete(*buffer);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
                return false;
            }
            buffer->append(chunk, (size_t)n);
            if (buffer->size() > kMaxReply) return false;
        }
        return true;
    }

private:
    int fd_ = -1;
};

size_t rprtCount(const std::string &s) {
    size_t n = 0;
    for (size_t at = s.find("RPRT "); at != std::string::npos; at = s.find("RPRT ", at + 1))
        if (s.find('\n', at) != std::string::npos) ++n;
    return n;
}

// rigctld: frequency and mode; again with currVFO if rigctld runs with --vfo.
bool readRigctld(const std::string &host, int port, ADIFRadioReading *r, std::string *error) {
    Socket s;
    if (!s.open(host, port, error)) return false;
    for (bool vfoMode : {false, true}) {
        std::string reply;
        if (!s.send(adif::rigctldQuery(vfoMode)) ||
            !s.readUntil(&reply, [](const std::string &b) { return rprtCount(b) >= 2; })) {
            *error = "rigctld at " + host + ":" + std::to_string(port) + " did not answer";
            return false;
        }
        std::vector<adif::RigctldBlock> blocks = adif::parseRigctld(reply);
        if (blocks.size() >= 2 && blocks[0].result == 0 && blocks[1].result == 0 && blocks[0].values.count("Frequency") &&
            blocks[1].values.count("Mode")) {
            r->hz = blocks[0].values["Frequency"];
            r->rigMode = blocks[1].values["Mode"];
            return true;
        }
        if (vfoMode || blocks.empty()) {
            int code = blocks.empty() ? 0 : (blocks[0].result != 0 ? blocks[0].result : blocks.size() > 1 ? blocks[1].result : 0);
            *error = "rigctld could not read the radio (RPRT " + std::to_string(code) + "); is the radio on and connected?";
            return false;
        }
    }
    return false;
}

bool flrigCall(const std::string &host, int port, const char *method, std::string *value, std::string *error) {
    Socket s;
    if (!s.open(host, port, error)) return false;
    std::string reply, body, fault;
    int status = 0;
    if (!s.send(adif::httpPost(host, port, adif::xmlRpcRequest(method))) ||
        !s.readUntil(&reply, [&](const std::string &b) { return adif::httpResponse(b, &status, &body); })) {
        *error = "flrig at " + host + ":" + std::to_string(port) + " did not answer";
        return false;
    }
    if (status != 200) {
        *error = "flrig answered HTTP " + std::to_string(status);
        return false;
    }
    if (!adif::xmlRpcValue(body, value, &fault)) {
        *error = "flrig: " + fault;
        return false;
    }
    return true;
}

bool readFlrig(const std::string &host, int port, ADIFRadioReading *r, std::string *error) {
    if (!flrigCall(host, port, "rig.get_xcvr", &r->rigName, error)) return false;
    if (r->rigName.empty()) {
        // flrig answers 14070000 and USB when it has no radio, so stop here.
        *error = "flrig is running but not connected to a radio";
        return false;
    }
    return flrigCall(host, port, "rig.get_vfo", &r->hz, error) && flrigCall(host, port, "rig.get_mode", &r->rigMode, error);
}

}  // namespace

void ADIFReadRadio(ADIFRadioKind kind, NSString *host, int port, void (^done)(const ADIFRadioReading &reading, NSString *error)) {
    std::string h = host.length ? std::string(host.UTF8String) : std::string("127.0.0.1");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ADIFRadioReading r;
        std::string error;
        bool ok = false;
        if (kind == ADIFRadioRigctld) ok = readRigctld(h, port, &r, &error);
        else if (kind == ADIFRadioFlrig) ok = readFlrig(h, port, &r, &error);
        else error = "no radio is set up";
        NSString *message = ok ? nil : [NSString stringWithUTF8String:error.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            done(r, message);
        });
    });
}
