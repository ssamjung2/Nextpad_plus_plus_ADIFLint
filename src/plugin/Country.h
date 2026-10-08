// The country table (AD1C's cty.csv) for Enrich from Country Data and New QSO:
// the copy downloaded by Settings → Country Data → Update (in the plugin config
// folder), else the copy installed next to ADIFLint.dylib.
#pragma once

#import <Foundation/Foundation.h>

#include "adif_country.h"

// Loaded on first use; empty when no copy could be read.
const adif::CountryTable &ADIFCountries(void);
// "Big CTY 15 September 2026 release, 346 entities (installed with ADIF Lint)".
NSString *ADIFCountryDataStatus(void);
// Download the newest release, check it parses, save it, use it. Completion on the main queue.
void ADIFUpdateCountryData(void (^done)(BOOL ok, NSString *message));
