// Operating Aids' scripts (adif_scripts.h) in the plugin: the scripts file (ADIFLint-scripts.adi in
// the config folder), and Edit Scripts, the window that adds, changes, hides and removes them, with
// each one written out as it would be now.
#pragma once

#include "adif_scripts.h"

#include <string>
#include <vector>

namespace scriptsui {

std::vector<adif::scripts::Script> all();                  // as you have them (the built-ins when there is no file)
void save(const std::vector<adif::scripts::Script> &list);  // then Operating Aids follow (adifhost::scriptsChanged)
void setShown(const std::string &id, bool shown);
// A script's name and text as they are shown: a built-in's translated until you change it.
std::string titleOf(const adif::scripts::Script &s);
std::string textOf(const adif::scripts::Script &s);
// Edit Scripts, with that script chosen ("" the first).
void cmdEditScripts(const std::string &id = "");

}  // namespace scriptsui
