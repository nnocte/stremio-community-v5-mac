#ifndef SELFTEST_H
#define SELFTEST_H

#include <string>
#include <vector>

// End-to-end protocol test mode (--self-test). The app loads a bundled harness
// page which drives the real JS bridge and mpv, and reports check results back.
bool SelfTestEnabled();
void SelfTestEnable();
void SelfTestBegin(const std::string &mediaPath, int timeoutSeconds);
void SelfTestHandleEvent(const std::string &ev, const std::vector<std::string> &args);

#endif // SELFTEST_H
