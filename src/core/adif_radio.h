// Reading the radio for New QSO: frequency and mode from Hamlib's rigctld or
// from flrig, turned into ADIF FREQ, MODE and SUBMODE. Pure C++17: the plugin
// does the socket work, this code builds the requests and reads the replies.
// Only queries are ever sent; nothing here can key or retune a radio.
//
// Sources (checked 2026-10-07):
//   rigctld(1), Hamlib 4.7.2 (21 June 2026): TCP port 4532; the Extended
//     Response Protocol ("+\get_freq") answers "get_freq:", "Frequency: N",
//     "RPRT 0"; get_mode answers "Mode: USB", "Passband: 2400"; with --vfo a
//     VFO argument such as currVFO is required. Mode tokens: USB LSB CW CWR
//     RTTY RTTYR AM FM WFM AMS PKTLSB PKTUSB PKTFM ECSSUSB ECSSLSB FA SAM SAL SAH DSB.
//   flrig src/server/xml_server.cxx (github.com/w1hkj/flrig, master):
//     XML-RPC on port 12345; rig.get_xcvr ("" when no radio is connected),
//     rig.get_vfo (active VFO in Hz), rig.get_mode (the radio's own mode name).
//     With no radio connected flrig still answers 14070000 and USB, so
//     rig.get_xcvr must be checked first.
#pragma once

#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace adif {

// "14074000" (Hz) -> "14.074" (ADIF FREQ is in MHz); a decimal part is rounded
// ("14074000.000000"). Empty when not a number.
std::string hzToMHz(std::string_view hz);

struct RigMode {
    std::string mode, submode;  // ADIF MODE and SUBMODE; empty when unknown
    bool data = false;          // a data mode (PKTUSB, DATA-U, USB-D...): the program decoding it knows the ADIF mode
};
// A Hamlib mode token or an flrig mode name -> ADIF.
RigMode mapRigMode(std::string_view rigMode);

// rigctld Extended Response Protocol: one block per command, ending "RPRT n".
struct RigctldBlock {
    std::string command;                       // the echoed long name, e.g. "get_freq"
    std::map<std::string, std::string> values; // "Frequency" -> "14074000"
    int result = 1;                            // RPRT value; 1 when the block has no RPRT yet
};
std::vector<RigctldBlock> parseRigctld(std::string_view reply);
// The query to send: frequency and mode, with "currVFO" when rigctld runs with --vfo.
std::string rigctldQuery(bool vfoMode);

// XML-RPC (flrig): a call without parameters, and the value of a response.
std::string xmlRpcRequest(std::string_view method);
// A string or number value; false with `fault` set for a <fault> or anything unreadable.
bool xmlRpcValue(std::string_view responseBody, std::string *value, std::string *fault);
// An HTTP/1.1 POST to /RPC2 carrying `body`.
std::string httpPost(std::string_view host, int port, std::string_view body);
// Split a complete HTTP response; false until the headers and Content-Length bytes are all there.
bool httpResponse(std::string_view raw, int *status, std::string *body);

}  // namespace adif
