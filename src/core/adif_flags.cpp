#include "adif_flags.h"

#include <algorithm>
#include <iterator>

namespace adif {

namespace {

struct FlagCode {
    int dxcc;
    const char *code;
};

// Current DXCC entities (ADIF 3.1.7's DXCC_Entity_Code), by code.
const FlagCode kFlags[] = {
    {1, "CA"}, {3, "AF"}, {4, "MU"}, {5, "AX"}, {6, "US"}, {7, "AL"}, {9, "AS"}, {10, "TF"}, {11, "IN"}, {12, "AI"},
    {13, "AQ"}, {14, "AM"}, {15, "RU"}, {16, "NZ"}, {17, "VE"}, {18, "AZ"}, {20, "UM"}, {21, "ES"}, {22, "PW"},
    {24, "BV"}, {27, "BY"}, {29, "IC"}, {31, "KI"}, {32, "EA"}, {33, "IO"}, {34, "NZ"}, {35, "CX"}, {36, "CP"},
    {37, "CR"}, {38, "CC"}, {40, "GR"}, {41, "TF"}, {43, "PR"}, {45, "GR"}, {46, "MY"}, {47, "CL"}, {48, "KI"},
    {49, "GQ"}, {50, "MX"}, {51, "ER"}, {52, "EE"}, {53, "ET"}, {54, "RU"}, {56, "BR"}, {60, "BS"}, {61, "RU"},
    {62, "BB"}, {63, "GF"}, {64, "BM"}, {65, "VG"}, {66, "BZ"}, {69, "KY"}, {70, "CU"}, {71, "EC"}, {72, "DO"},
    {74, "SV"}, {75, "GE"}, {76, "GT"}, {77, "GD"}, {78, "HT"}, {79, "GP"}, {80, "HN"}, {82, "JM"}, {84, "MQ"},
    {86, "NI"}, {88, "PA"}, {89, "TC"}, {90, "TT"}, {91, "AW"}, {94, "AG"}, {95, "DM"}, {96, "MS"}, {97, "LC"},
    {98, "VC"}, {99, "TF"}, {100, "AR"}, {103, "GU"}, {104, "BO"}, {105, "US"}, {106, "GG"}, {107, "GN"}, {108, "BR"},
    {109, "GW"}, {110, "US"}, {111, "HM"}, {112, "CL"}, {114, "IM"}, {116, "CO"}, {117, "UN"}, {118, "SJ"},
    {120, "EC"}, {122, "JE"}, {123, "UM"}, {124, "TF"}, {125, "CL"}, {126, "RU"}, {129, "GY"}, {130, "KZ"},
    {131, "TF"}, {132, "PY"}, {133, "NZ"}, {135, "KG"}, {136, "PE"}, {137, "KR"}, {138, "US"}, {140, "SR"},
    {141, "FK"}, {142, "IN"}, {143, "LA"}, {144, "UY"}, {145, "LV"}, {146, "LT"}, {147, "AU"}, {148, "VE"},
    {149, "PT"}, {150, "AU"}, {152, "MO"}, {153, "AU"}, {157, "NR"}, {158, "VU"}, {159, "MV"}, {160, "TO"},
    {161, "CO"}, {162, "NC"}, {163, "PG"}, {165, "MU"}, {166, "MP"}, {167, "AX"}, {168, "MH"}, {169, "YT"},
    {170, "NZ"}, {171, "AU"}, {172, "PN"}, {173, "FM"}, {174, "UM"}, {175, "PF"}, {176, "FJ"}, {177, "JP"},
    {179, "MD"}, {180, "GR"}, {181, "MZ"}, {182, "UM"}, {185, "SB"}, {187, "NE"}, {188, "NU"}, {189, "NF"},
    {190, "WS"}, {191, "CK"}, {192, "JP"}, {195, "GQ"}, {197, "UM"}, {199, "AQ"}, {201, "ZA"}, {202, "PR"},
    {203, "AD"}, {204, "MX"}, {205, "AC"}, {206, "AT"}, {207, "MU"}, {209, "BE"}, {211, "CA"}, {212, "BG"},
    {213, "MF"}, {214, "FR"}, {215, "CY"}, {216, "CO"}, {217, "CL"}, {219, "ST"}, {221, "DK"}, {222, "FO"},
    {223, "GB-ENG"}, {224, "FI"}, {225, "IT"}, {227, "FR"}, {230, "DE"}, {232, "SO"}, {233, "GI"}, {234, "CK"},
    {235, "GS"}, {236, "GR"}, {237, "GL"}, {238, "AQ"}, {239, "HU"}, {240, "GS"}, {241, "AQ"}, {242, "IS"},
    {245, "IE"}, {248, "IT"}, {249, "KN"}, {250, "SH"}, {251, "LI"}, {252, "CA"}, {253, "BR"}, {254, "LU"},
    {256, "PT"}, {257, "MT"}, {259, "SJ"}, {260, "MC"}, {262, "TJ"}, {263, "NL"}, {265, "GB"}, {266, "NO"},
    {269, "PL"}, {270, "TK"}, {272, "PT"}, {273, "BR"}, {274, "TA"}, {275, "RO"}, {276, "TF"}, {277, "PM"},
    {278, "SM"}, {279, "GB-SCT"}, {280, "TM"}, {281, "ES"}, {282, "TV"}, {283, "GB"}, {284, "SE"}, {285, "VI"},
    {286, "UG"}, {287, "CH"}, {288, "UA"}, {289, "UN"}, {291, "US"}, {292, "UZ"}, {293, "VN"}, {294, "GB-WLS"},
    {295, "VA"}, {296, "RS"}, {297, "UM"}, {298, "WF"}, {299, "MY"}, {301, "KI"}, {302, "EH"}, {303, "AU"},
    {304, "BH"}, {305, "BD"}, {306, "BT"}, {308, "CR"}, {309, "MM"}, {312, "KH"}, {315, "LK"}, {318, "CN"},
    {321, "HK"}, {324, "IN"}, {327, "ID"}, {330, "IR"}, {333, "IQ"}, {336, "IL"}, {339, "JP"}, {342, "JO"},
    {344, "KP"}, {345, "BN"}, {348, "KW"}, {354, "LB"}, {363, "MN"}, {369, "NP"}, {370, "OM"}, {372, "PK"},
    {375, "PH"}, {376, "QA"}, {378, "SA"}, {379, "SC"}, {381, "SG"}, {382, "DJ"}, {384, "SY"}, {386, "TW"},
    {387, "TH"}, {390, "TR"}, {391, "AE"}, {400, "DZ"}, {401, "AO"}, {402, "BW"}, {404, "BI"}, {406, "CM"},
    {408, "CF"}, {409, "CV"}, {410, "TD"}, {411, "KM"}, {412, "CG"}, {414, "CD"}, {416, "BJ"}, {420, "GA"},
    {422, "GM"}, {424, "GH"}, {428, "CI"}, {430, "KE"}, {432, "LS"}, {434, "LR"}, {436, "LY"}, {438, "MG"},
    {440, "MW"}, {442, "ML"}, {444, "MR"}, {446, "MA"}, {450, "NG"}, {452, "ZW"}, {453, "RE"}, {454, "RW"},
    {456, "SN"}, {458, "SL"}, {460, "FJ"}, {462, "ZA"}, {464, "NA"}, {466, "SD"}, {468, "SZ"}, {470, "TZ"},
    {474, "TN"}, {478, "EG"}, {480, "BF"}, {482, "ZM"}, {483, "TG"}, {489, "FJ"}, {490, "KI"}, {492, "YE"},
    {497, "HR"}, {499, "SI"}, {501, "BA"}, {502, "MK"}, {503, "CZ"}, {504, "SK"}, {505, "TW"}, {507, "SB"},
    {508, "PF"}, {509, "PF"}, {510, "PS"}, {511, "TL"}, {512, "NC"}, {513, "PN"}, {514, "ME"}, {515, "AS"},
    {516, "BL"}, {517, "CW"}, {518, "SX"}, {519, "BQ"}, {520, "BQ"}, {521, "SS"}, {522, "XK"},
};

void appendUtf8(std::string &out, char32_t c) {
    if (c < 0x80) out += (char)c;
    else if (c < 0x800) out += (char)(0xC0 | (c >> 6)), out += (char)(0x80 | (c & 0x3F));
    else if (c < 0x10000) out += (char)(0xE0 | (c >> 12)), out += (char)(0x80 | ((c >> 6) & 0x3F)), out += (char)(0x80 | (c & 0x3F));
    else
        out += (char)(0xF0 | (c >> 18)), out += (char)(0x80 | ((c >> 12) & 0x3F)), out += (char)(0x80 | ((c >> 6) & 0x3F)),
            out += (char)(0x80 | (c & 0x3F));
}

}  // namespace

std::string dxccFlagCode(int dxcc) {
    auto it = std::lower_bound(std::begin(kFlags), std::end(kFlags), dxcc, [](const FlagCode &f, int d) { return f.dxcc < d; });
    return it != std::end(kFlags) && it->dxcc == dxcc ? it->code : "";
}

std::string dxccFlag(int dxcc) {
    std::string code = dxccFlagCode(dxcc), out;
    if (code.size() == 2) {  // regional indicator letters: U+1F1E6 is A
        for (char c : code) appendUtf8(out, 0x1F1E6 + (char32_t)(c - 'A'));
    } else if (code.size() == 6 && code.compare(0, 3, "GB-") == 0) {
        // A black flag, the subdivision's code in tag letters ("gbeng"), and the cancel tag (UTS #51 annex C).
        appendUtf8(out, 0x1F3F4);
        std::string sub = "gb" + code.substr(3);
        for (char c : sub) appendUtf8(out, 0xE0000 + (char32_t)(c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c));
        appendUtf8(out, 0xE007F);
    }
    return out;
}

}  // namespace adif
