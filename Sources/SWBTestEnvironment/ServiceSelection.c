//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#include "SWBTestEnvironment.h"

#include <stdlib.h>

// Tests exercise the build service that was built with them. A service selected for Xcode through the environment,
// for example one that the login session exports to every process, would silently replace it for every test.
// Discard the inherited selection before any test reads the environment. Tests which select a service themselves
// do so after the process has started and are unaffected.
__attribute__((constructor))
static void swb_test_discard_inherited_service_selection(void) {
    static const char *const names[] = {
        "SWBBUILDSERVICE_PATH",
        "XCBBUILDSERVICE_PATH",
        "SWBBUILDSERVICE_BUNDLE_PATH",
        "XCBBUILDSERVICE_BUNDLE_PATH",
    };
    for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
#if defined(_WIN32)
        _putenv_s(names[index], "");
#else
        unsetenv(names[index]);
#endif
    }
}
