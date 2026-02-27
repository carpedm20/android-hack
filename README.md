# android-hack

Bypass Google's PairIP (Play Auto Integrity Protection) on Android apps to run them on emulators.

Tested on **Vogue Runway** (com.condenast.voguerunway v12.60.1) — a Flutter app protected by PairIP that refuses to run on emulators. Designed to work generically with any PairIP-protected Flutter app.

## What is PairIP?

PairIP (`libpairipcore.so`) is Google's VM-based app integrity protection system. It operates at three layers:

1. **Native code encryption** — Encrypts functions inside `libflutter.so`'s `.text` section. At startup, `DT_INIT` calls `ExecuteProgram` (from `libpairipcore.so`) to decrypt them. Without decryption, the app hits SIGILL on encrypted instructions.

2. **String vault VM** — Reads encrypted bytecode from APK assets and executes a custom VM (`executeVM`) to populate ~1,400 static String fields across ~32 "vault" classes. These strings hold field names, class names, method names, SQL statements, API keys, etc. used throughout the app via Java reflection.

3. **Integrity checks** — `SignatureCheck`, `LicenseContentProvider`, and environment detection to block modified APKs and emulators.

## How the Bypass Works

The script applies **10 layers of patches** to make PairIP-protected apps runnable:

| Layer | Problem | Solution |
|-------|---------|----------|
| Native encryption | `libpairipcore.so` encrypts functions in libflutter.so | Replace with stock Flutter engine (same version) |
| String vault VM | VM populates ~1,400 strings at startup | Initialize all to `""`, auto-detect and patch critical reflection strings |
| PairIP Java classes | VMRunner, StartupLauncher, SignatureCheck | Rewrite as no-ops (return-void / return null) |
| ContentProviders | Firebase, GMS Ads, PairIP License crash without init | Disable in AndroidManifest (`android:enabled="false"`) |
| Protobuf/Tink | Empty vault strings used as field names → crash | Return fallback field for empty names, try-catch crypto init |
| Background crashes | SDKs crash on empty SQL/strings | SafeExceptionHandler catches non-main-thread exceptions |
| Missing assets | Compiled Dart uses `app/assets/` prefix but manifest has `assets/` | Auto-detect from libapp.so, copy and update AssetManifest |
| Crash-prone native libs | libembrace-native.so causes SIGILL; Embrace.start() NPEs | Auto-remove native libs, wrap SDK init in try-catch |
| Kotlin property strings | Vault strings used as Kotlin property names → NoSuchElementException | Auto-detect from getter signatures (e.g., `getAction()` → `"action"`) |
| MethodChannel/SecureStorage | Plugin handlers crash on empty vault strings; cipher null → NPE | Wrap onMethodCall in try-catch; cipher null-guard fallback |

### Why replace libflutter.so?

PairIP encrypts individual functions inside `libflutter.so` using custom bytecode. The encrypted bytes look like invalid ARM64 instructions (SVE-like `0x26e16011`, unallocated `0xd740600f`). Patching individual functions is impractical — there are hundreds, and we'd need to reverse-engineer PairIP's decryption VM.

Instead, we replace the entire `libflutter.so` with the **stock Flutter engine** of the same version. Since Flutter's exported API is stable, all 50 exported symbols match exactly between the app's encrypted engine and the stock one.

### Auto-detected vault strings

The script automatically detects critical vault strings from two sources:

1. **Reflection analysis** — Scans smali for vault fields used in `AtomicFieldUpdater.newUpdater`, `Class.forName`, `Class.getMethod`, etc. and extracts the correct values from the call context (volatile field names, class names, method names).

2. **Kotlin property references** — Scans for vault fields used as Kotlin property names by detecting getter method signatures (e.g., `getAction()Ljava/lang/String;` → field value should be `"action"`).

The remaining ~1,385 strings stay empty. Most SDK features still work — the SafeExceptionHandler silently catches background thread crashes caused by empty strings.

## Usage

### Quick start (recommended)

```bash
# One command to patch (if needed), launch emulator, start proxy, and run the app:
./launch.sh                              # auto-finds APK in common locations
./launch.sh ~/Downloads/Vogue.apk        # specify APK path
./launch.sh --no-proxy                   # launch without proxy
./launch.sh --proxy-port 9090            # use custom proxy port
./launch.sh --no-emulator --no-install   # just launch the app
./launch.sh --reinstall                  # force reinstall
```

`launch.sh` handles everything automatically:
- Starts mitmproxy (mitmweb) if not running
- Starts the emulator if not running
- Sets or clears the system proxy dynamically (no emulator restart needed)
- Installs mitmproxy CA cert as system certificate if needed
- Auto-detects package name and activity from patch metadata
- Calls `patch_pairip.sh` if the patched APK doesn't exist yet
- Installs and launches the app

#### Login first, then enable proxy

Some apps require login before you can capture traffic. Since the proxy's CA cert can cause "connection not private" errors in Chrome/WebView login flows, use `--no-proxy` first:

```bash
# 1. Launch without proxy — log in normally
./launch.sh --no-proxy

# 2. After login, relaunch with proxy to capture traffic
./launch.sh --no-install --no-patch
```

Flutter/Dart ignores Android's system proxy setting — the only way to capture Flutter traffic is the emulator's `-http-proxy` flag, which intercepts at the QEMU network level. `launch.sh` automatically restarts the emulator when toggling proxy on/off. Your login session persists across restarts since app data is stored on the emulator's virtual disk.

#### launch.sh options

| Flag | Description |
|------|-------------|
| `--no-proxy` | Disable mitmproxy (no proxy setup) |
| `--proxy-port PORT` | Set proxy port (default: 8080) |
| `--no-emulator` | Skip emulator start (assume already running) |
| `--no-install` | Skip APK installation |
| `--reinstall` | Force uninstall + reinstall even if already installed |
| `--no-launch` | Skip app launch |
| `--no-cert` | Skip CA cert installation |
| `--no-patch` | Skip APK patching (use existing patched APK) |
| `--cold-boot` | Cold boot emulator (discard snapshot, slower but clean) |
| `--avd NAME` | Use a different AVD (default: vogue_lab) |
| `-h, --help` | Show usage |

### First-time setup

```bash
# On a fresh Mac — the script handles everything:
#   - Installs Java, Android SDK, emulator, system image
#   - Creates and boots an AVD
#   - Decompiles, patches, builds, signs, installs, launches

./patch_pairip.sh <path-to-apk>
```

### Prerequisites

The script auto-installs most dependencies, but you need:
- **macOS** (Apple Silicon or Intel)
- **Homebrew** (auto-installed if missing)
- **mitmproxy** or **Charles Proxy** (for traffic inspection)
- ~10 GB free disk space (SDK + emulator image + APK)

### What the script does (16 steps)

```
 Step  1: Check/install Homebrew, Java, Python 3
 Step  2: Download Android SDK, install platform-tools, build-tools, emulator, system-image
 Step  3: Create AVD "vogue_lab" (Pixel 5, Android 14, arm64, 2GB RAM)
 Step  4: Start emulator with writable-system, wait for boot
 Step  5: Download apktool 2.10.0
 Step  6: Decompile APK (auto-detect package name + main activity)
 Step  7: Replace encrypted libflutter.so with stock Flutter engine
 Step  8: Disable PairIP Java classes (VMRunner, StartupLauncher, SignatureCheck)
 Step  9: Disable crash-prone ContentProviders in AndroidManifest.xml
 Step 10: Initialize ~32 vault classes, auto-detect critical reflection strings
 Step 11: Patch protobuf field lookup + wrap Tink crypto init in try-catch
 Step 12: Create SafeExceptionHandler for background thread crashes
 Step 13: Fix Flutter asset paths + remove crash-prone native libs (Embrace)
 Step 14: Patch remaining crashes (Snowplow, SecureStorage, MethodChannels)
 Step 15: Build, zipalign, sign APK
 Step 16: Install and launch on emulator
```

### First launch notes

- First launch takes **2-3 minutes** due to DEX verification on the emulator
- Tap **"Wait"** if the "App not responding" dialog appears
- Subsequent launches are fast (DEX verification is cached)

### Useful commands after launch

```bash
# View all app logs (replace PACKAGE with your app's package name)
adb logcat --pid=$(adb shell pidof PACKAGE)

# View Flutter/Dart logs only
adb logcat --pid=$(adb shell pidof PACKAGE) | grep flutter

# View caught background exceptions
adb logcat --pid=$(adb shell pidof PACKAGE) | grep SafeExceptionHandler

# Relaunch the app
adb shell am start -n PACKAGE/ACTIVITY

# Start emulator (if closed)
~/Library/Android/sdk/emulator/emulator -avd vogue_lab \
  -writable-system \
  -no-snapshot-load \
  -gpu host &

# Toggle proxy on/off without restarting emulator
adb shell settings put global http_proxy 10.0.2.2:8080   # proxy ON
adb shell settings put global http_proxy :0               # proxy OFF
```

## Proxy Setup (Intercepting API Traffic)

The proxy is controlled dynamically via Android's system proxy setting (`adb shell settings put global http_proxy`). This means you can toggle it on/off without restarting the emulator — useful for logging in without proxy first, then enabling it to capture API traffic.

### 1. Install and start mitmproxy

```bash
brew install mitmproxy
mitmproxy --listen-port 8080
# or for a web UI:
mitmweb --listen-port 8080
```

### 2. Install mitmproxy's CA certificate on the emulator

Android 14 requires system-level CA certificates for HTTPS interception. The `-writable-system` flag enables this:

```bash
# Wait for boot, then install the CA cert
adb root
adb remount

# Convert mitmproxy cert to Android system cert format
CERT_HASH=$(openssl x509 -inform PEM -subject_hash_old \
  -in ~/.mitmproxy/mitmproxy-ca-cert.cer 2>/dev/null | head -1)
openssl x509 -inform PEM \
  -in ~/.mitmproxy/mitmproxy-ca-cert.cer \
  -out /tmp/mitmproxy-ca-cert.pem
cp /tmp/mitmproxy-ca-cert.pem "/tmp/${CERT_HASH}.0"

# Push to system CA store
adb push "/tmp/${CERT_HASH}.0" "/system/etc/security/cacerts/${CERT_HASH}.0"
adb shell chmod 644 "/system/etc/security/cacerts/${CERT_HASH}.0"

# Reboot to apply
adb reboot
```

### 3. Disable SSL pinning (if needed)

Flutter apps often use their own certificate validation. The stock Flutter engine we injected does NOT have certificate pinning compiled in (unlike the original PairIP-encrypted one), so most HTTPS traffic should be visible through the proxy.

If you still see SSL errors in logcat:
```
E FirebaseCrashlytics: javax.net.ssl.SSLHandshakeException: Trust anchor for certification path not found
```
This means some SDK (not Flutter) is doing its own pinning. These are non-critical — the core Flutter/Dart API calls should go through the proxy fine.

### 4. View traffic

```bash
# mitmproxy TUI (terminal)
mitmproxy --listen-port 8080

# mitmweb (browser UI at http://127.0.0.1:8081)
mitmweb --listen-port 8080

# Charles Proxy: set port to 8080 in Proxy Settings
```

## Adapting to Other Apps

The script is designed to work generically with any PairIP-protected Flutter app. Just run:

```bash
./patch_pairip.sh <path-to-any-pairip-apk>
```

The script auto-detects:
- **Package name and main activity** from AndroidManifest.xml
- **Flutter engine version** from the libflutter.so binary
- **Vault string values** from reflection call context and Kotlin property signatures
- **Asset path mismatches** from libapp.so string analysis
- **Crash-prone native libs** (Embrace, PairIP core) for removal

If the auto-detection misses some vault strings for a specific app, you may need to:
1. Check logcat for remaining crashes
2. Trace the crash back to a vault string field
3. Add the correct value to the `KNOWN_STRINGS` dict in step 10

## Limitations

- **~1,400 vault strings are empty** — Core UI works but some SDK integrations (analytics, push notifications, ad mediation) have degraded functionality
- **Network calls may fail** — API keys and endpoint URLs stored in vault strings are empty
- **Flutter engine must match exactly** — If the app updates its Flutter version, you need to find the new engine commit
- **PairIP updates** — Google may change PairIP's protection scheme in future versions

## Tools Used

- [apktool](https://apktool.org/) — APK decompilation and rebuilding
- [Android SDK](https://developer.android.com/studio/command-line) — build-tools (zipalign, apksigner), emulator, platform-tools
- Python 3 — smali code patching
- Stock Flutter engine from [Google Cloud Storage](https://storage.googleapis.com/flutter_infra_release/)
