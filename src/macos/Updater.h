#ifndef UPDATER_H
#define UPDATER_H

// Signed update checks (Windows: src/updater/updater.cpp). Downloads go
// through NSURLSession, the signature is verified with Security.framework.
void RunAutoUpdaterOnce();
void RunInstallerAndExit();

#endif // UPDATER_H
