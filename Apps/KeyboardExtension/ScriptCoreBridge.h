#import "DocumentIdentityBridge.h"

// Shared C script runtime (Tools/Script). These are declarations only: the engine and the C bridge
// are compiled into the extension (and into the XCTest bundle) from Tools/Script/src, so Swift and
// the tests reach the same parser and runner the macOS command-line tool uses.
#include "songyan_script.h"
#include "songyan_script_run.h"
