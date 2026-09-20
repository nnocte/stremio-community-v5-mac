#ifndef SPLASH_H
#define SPLASH_H

// Splash overlay shown until the web UI reports "app-ready"
// (Windows: src/ui/splash.cpp).
void CreateSplashScreen();
void HideSplash();

// Keeps the splash above the (later added) web view.
void ShellBringSplashToFront();

// True while the splash overlay is on screen (used by the self test).
bool SplashVisible();

#endif // SPLASH_H
