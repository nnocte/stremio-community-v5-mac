#include "Power.h"

#import <IOKit/pwr_mgt/IOPMLib.h>

#include <iostream>

#include "Log.h"

namespace {
IOPMAssertionID g_assertion = kIOPMNullAssertionID;
bool g_blocked = false;
} // namespace

void SetDisplaySleepBlocked(bool blocked) {
  if (blocked == g_blocked) return;
  g_blocked = blocked;

  if (blocked) {
    IOReturn result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep,
                                                  kIOPMAssertionLevelOn,
                                                  CFSTR("Stremio playback"),
                                                  &g_assertion);
    if (result != kIOReturnSuccess) {
      g_assertion = kIOPMNullAssertionID;
      AppendToCrashLog("[POWER]: Could not create display sleep assertion");
    }
  } else if (g_assertion != kIOPMNullAssertionID) {
    IOPMAssertionRelease(g_assertion);
    g_assertion = kIOPMNullAssertionID;
  }
}
