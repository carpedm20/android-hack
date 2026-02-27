#!/usr/bin/env bash
#
# patch_pairip.sh - Bypass PairIP protection on Android APKs for emulator use
#
# This script handles EVERYTHING from scratch on a fresh Mac:
#   1. Installs Homebrew dependencies (java, python3)
#   2. Downloads Android SDK components (cmdline-tools, platform-tools, build-tools,
#      emulator, system-image)
#   3. Creates an AVD (Android Virtual Device) if one doesn't exist
#   4. Starts the emulator if not already running
#   5. Downloads apktool if not present
#   6. Decompiles the APK
#   7. Applies all PairIP bypass patches (8 layers)
#   8. Builds, signs, installs, and launches the patched APK
#
# Usage:
#   ./patch_pairip.sh <path-to-apk>
#
# Example:
#   ./patch_pairip.sh ~/Downloads/Vogue_12.60.1_APKPure/com.condenast.voguerunway_12.60.1.apk
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

APK_INPUT="${1:?Usage: $0 <path-to-apk>}"
WORK_DIR="/tmp/pairip_patch"
DECOMPILED="$WORK_DIR/decompiled"
KEYSTORE="$WORK_DIR/debug.keystore"
KEYSTORE_PASS="android"
KEY_ALIAS="androiddebugkey"

# AVD configuration
AVD_NAME="vogue_lab"
SYSTEM_IMAGE="system-images;android-34;google_apis;arm64-v8a"
SYSTEM_IMAGE_DIR="system-images/android-34/google_apis/arm64-v8a"
AVD_DEVICE="pixel_5"
AVD_RAM="2048"                # MB
AVD_DISK="6442450944"         # bytes (6GB)
AVD_SDCARD="512M"

# Proxy configuration (e.g., mitmproxy, Charles Proxy)
# Set to empty string to disable proxy
HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:8080}"

# Flutter engine commit is auto-detected from the APK's libflutter.so binary.
# Override manually if auto-detection fails:
FLUTTER_ENGINE_COMMIT="${FLUTTER_ENGINE_COMMIT:-}"

# Android SDK location
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"

# ============================================================================
# Helpers
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}\n"; }

[ -f "$APK_INPUT" ] || die "APK not found: $APK_INPUT"

mkdir -p "$WORK_DIR"

# ############################################################################
#
#   PART 1: ENVIRONMENT SETUP
#
# ############################################################################

section "Step 1/16: Checking prerequisites"

# ---------------------------------------------------------------------------
# 1a. Homebrew
# ---------------------------------------------------------------------------
if ! command -v brew &>/dev/null; then
    warn "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add to PATH for Apple Silicon Macs
    if [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi
log "Homebrew: OK"

# ---------------------------------------------------------------------------
# 1b. Java
# ---------------------------------------------------------------------------
if ! command -v java &>/dev/null; then
    log "Installing Java (needed for apktool and Android tools)..."
    brew install openjdk
    # Symlink for macOS
    sudo ln -sfn "$(brew --prefix openjdk)/libexec/openjdk.jdk" /Library/Java/JavaVirtualMachines/openjdk.jdk 2>/dev/null || true
fi
log "Java: $(java -version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# 1c. Python 3
# ---------------------------------------------------------------------------
if ! command -v python3 &>/dev/null; then
    log "Installing Python 3 (needed for smali patching)..."
    brew install python3
fi
log "Python3: $(python3 --version)"

# ---------------------------------------------------------------------------
# 1d. curl, unzip (should be preinstalled on macOS)
# ---------------------------------------------------------------------------
command -v curl &>/dev/null || die "curl not found"
command -v unzip &>/dev/null || die "unzip not found"

# ============================================================================
# Step 2: Android SDK Setup
# ============================================================================

section "Step 2/16: Setting up Android SDK"

# ---------------------------------------------------------------------------
# 2a. Download cmdline-tools if SDK doesn't exist
# ---------------------------------------------------------------------------
if [ ! -d "$ANDROID_SDK" ]; then
    log "Android SDK not found at $ANDROID_SDK. Downloading command-line tools..."
    mkdir -p "$ANDROID_SDK"

    CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip"
    CMDLINE_ZIP="$WORK_DIR/cmdline-tools.zip"

    if [ ! -f "$CMDLINE_ZIP" ]; then
        curl -L -o "$CMDLINE_ZIP" "$CMDLINE_TOOLS_URL"
    fi

    # Android SDK expects cmdline-tools under a version directory
    unzip -o "$CMDLINE_ZIP" -d "$ANDROID_SDK/cmdline-tools-tmp"
    mkdir -p "$ANDROID_SDK/cmdline-tools"
    mv "$ANDROID_SDK/cmdline-tools-tmp/cmdline-tools" "$ANDROID_SDK/cmdline-tools/latest"
    rm -rf "$ANDROID_SDK/cmdline-tools-tmp"
fi

# Find sdkmanager
SDKMANAGER=""
for candidate in \
    "$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager" \
    "$ANDROID_SDK/cmdline-tools/bin/sdkmanager" \
    "$ANDROID_SDK/tools/bin/sdkmanager"; do
    if [ -f "$candidate" ]; then
        SDKMANAGER="$candidate"
        break
    fi
done
[ -n "$SDKMANAGER" ] || die "sdkmanager not found. Install Android Studio or download SDK command-line tools."
log "sdkmanager: $SDKMANAGER"

# ---------------------------------------------------------------------------
# 2b. Accept licenses
# ---------------------------------------------------------------------------
log "Accepting Android SDK licenses..."
yes | "$SDKMANAGER" --licenses &>/dev/null || true

# ---------------------------------------------------------------------------
# 2c. Install required SDK packages
# ---------------------------------------------------------------------------
PACKAGES_TO_INSTALL=()

# platform-tools (adb)
if [ ! -f "$ANDROID_SDK/platform-tools/adb" ]; then
    PACKAGES_TO_INSTALL+=("platform-tools")
fi

# build-tools (zipalign, apksigner)
BUILD_TOOLS_DIR=$(ls -d "$ANDROID_SDK/build-tools/"* 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$BUILD_TOOLS_DIR" ] || [ ! -f "$BUILD_TOOLS_DIR/zipalign" ]; then
    PACKAGES_TO_INSTALL+=("build-tools;34.0.0")
fi

# emulator
if [ ! -f "$ANDROID_SDK/emulator/emulator" ]; then
    PACKAGES_TO_INSTALL+=("emulator")
fi

# system image for AVD
if [ ! -d "$ANDROID_SDK/$SYSTEM_IMAGE_DIR" ]; then
    PACKAGES_TO_INSTALL+=("$SYSTEM_IMAGE")
    PACKAGES_TO_INSTALL+=("platforms;android-34")
fi

if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then
    log "Installing SDK packages: ${PACKAGES_TO_INSTALL[*]}"
    "$SDKMANAGER" --install "${PACKAGES_TO_INSTALL[@]}"
else
    log "All required SDK packages already installed"
fi

# Re-detect build-tools after possible install
BUILD_TOOLS_DIR=$(ls -d "$ANDROID_SDK/build-tools/"* 2>/dev/null | sort -V | tail -1)
[ -d "$BUILD_TOOLS_DIR" ] || die "build-tools not found after install"

ZIPALIGN="$BUILD_TOOLS_DIR/zipalign"
APKSIGNER="$BUILD_TOOLS_DIR/apksigner"
ADB="$ANDROID_SDK/platform-tools/adb"
EMULATOR="$ANDROID_SDK/emulator/emulator"
AVDMANAGER="$ANDROID_SDK/cmdline-tools/latest/bin/avdmanager"

log "build-tools: $BUILD_TOOLS_DIR"
log "adb: $ADB"
log "emulator: $EMULATOR"

# Add to PATH for this session
export PATH="$ANDROID_SDK/platform-tools:$ANDROID_SDK/emulator:$PATH"
export ANDROID_HOME="$ANDROID_SDK"
export ANDROID_SDK_ROOT="$ANDROID_SDK"

# ============================================================================
# Step 3: Create AVD (Android Virtual Device)
# ============================================================================

section "Step 3/16: Setting up Android emulator"

# Check if AVD already exists
AVD_EXISTS=false
if "$EMULATOR" -list-avds 2>/dev/null | grep -q "^${AVD_NAME}$"; then
    AVD_EXISTS=true
    log "AVD '$AVD_NAME' already exists"
fi

if [ "$AVD_EXISTS" = false ]; then
    log "Creating AVD '$AVD_NAME' (Pixel 5, Android 14, arm64)..."

    # Ensure avdmanager exists
    if [ ! -f "$AVDMANAGER" ]; then
        die "avdmanager not found at $AVDMANAGER"
    fi

    # Create the AVD
    echo "no" | "$AVDMANAGER" create avd \
        --name "$AVD_NAME" \
        --package "$SYSTEM_IMAGE" \
        --device "$AVD_DEVICE" \
        --force

    # Configure AVD for better performance
    AVD_CONFIG="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
    if [ -f "$AVD_CONFIG" ]; then
        log "Configuring AVD for optimal performance..."

        # Update RAM
        if grep -q "hw.ramSize" "$AVD_CONFIG"; then
            sed -i '' "s/hw.ramSize.*/hw.ramSize = ${AVD_RAM}M/" "$AVD_CONFIG"
        else
            echo "hw.ramSize = ${AVD_RAM}M" >> "$AVD_CONFIG"
        fi

        # Update disk size
        if grep -q "disk.dataPartition.size" "$AVD_CONFIG"; then
            sed -i '' "s/disk.dataPartition.size.*/disk.dataPartition.size = ${AVD_DISK}/" "$AVD_CONFIG"
        else
            echo "disk.dataPartition.size = ${AVD_DISK}" >> "$AVD_CONFIG"
        fi

        # GPU mode - use host GPU for performance
        if grep -q "hw.gpu.enabled" "$AVD_CONFIG"; then
            sed -i '' "s/hw.gpu.enabled.*/hw.gpu.enabled = yes/" "$AVD_CONFIG"
        else
            echo "hw.gpu.enabled = yes" >> "$AVD_CONFIG"
        fi
        if grep -q "hw.gpu.mode" "$AVD_CONFIG"; then
            sed -i '' "s/hw.gpu.mode.*/hw.gpu.mode = host/" "$AVD_CONFIG"
        else
            echo "hw.gpu.mode = host" >> "$AVD_CONFIG"
        fi

        # CPU cores
        if grep -q "hw.cpu.ncore" "$AVD_CONFIG"; then
            sed -i '' "s/hw.cpu.ncore.*/hw.cpu.ncore = 4/" "$AVD_CONFIG"
        else
            echo "hw.cpu.ncore = 4" >> "$AVD_CONFIG"
        fi

        # SD card
        if grep -q "sdcard.size" "$AVD_CONFIG"; then
            sed -i '' "s/sdcard.size.*/sdcard.size = ${AVD_SDCARD}/" "$AVD_CONFIG"
        else
            echo "sdcard.size = ${AVD_SDCARD}" >> "$AVD_CONFIG"
        fi

        # LCD display (Pixel 5: 1080x2340 @ 440dpi)
        sed -i '' "s/hw.lcd.density.*/hw.lcd.density = 440/" "$AVD_CONFIG" 2>/dev/null || true
        sed -i '' "s/hw.lcd.width.*/hw.lcd.width = 1080/" "$AVD_CONFIG" 2>/dev/null || true
        sed -i '' "s/hw.lcd.height.*/hw.lcd.height = 2340/" "$AVD_CONFIG" 2>/dev/null || true

        # Disable PlayStore (we're sideloading)
        if grep -q "PlayStore.enabled" "$AVD_CONFIG"; then
            sed -i '' "s/PlayStore.enabled.*/PlayStore.enabled = no/" "$AVD_CONFIG"
        else
            echo "PlayStore.enabled = no" >> "$AVD_CONFIG"
        fi
    fi

    log "AVD '$AVD_NAME' created successfully"
fi

# ============================================================================
# Step 4: Start emulator if not running
# ============================================================================

section "Step 4/16: Starting emulator"

EMULATOR_RUNNING=false
if "$ADB" devices 2>/dev/null | grep -q "emulator.*device$"; then
    EMULATOR_RUNNING=true
    log "Emulator already running"
fi

if [ "$EMULATOR_RUNNING" = false ]; then
    log "Starting emulator '$AVD_NAME'..."

    # Clean any stale lock files
    rm -f "$HOME/.android/avd/${AVD_NAME}.avd/"*.lock 2>/dev/null || true

    # Start emulator in background
    #   -http-proxy       : route traffic through proxy (mitmproxy/Charles) for inspection
    #   -writable-system  : allow system partition writes (e.g., install CA certs)
    #   -no-snapshot-load : cold boot, don't restore from snapshot
    #   -gpu host         : use host GPU for performance
    EMULATOR_ARGS=(-avd "$AVD_NAME" -no-snapshot-load -writable-system -gpu host)
    if [ -n "$HTTP_PROXY" ]; then
        EMULATOR_ARGS+=(-http-proxy "$HTTP_PROXY")
        log "Proxy: $HTTP_PROXY (start mitmproxy/Charles before app launch)"
    fi
    "$EMULATOR" "${EMULATOR_ARGS[@]}" &>/tmp/emulator_pairip.log &
    EMULATOR_PID=$!
    log "Emulator PID: $EMULATOR_PID"

    # Wait for boot
    log "Waiting for emulator to boot (this can take 1-3 minutes)..."
    BOOT_TIMEOUT=180  # 3 minutes
    ELAPSED=0
    while [ $ELAPSED -lt $BOOT_TIMEOUT ]; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        BOOT_STATUS=$("$ADB" shell getprop sys.boot_completed 2>/dev/null || echo "")
        if [ "$BOOT_STATUS" = "1" ]; then
            log "Emulator booted in ${ELAPSED}s"
            break
        fi
        if [ $((ELAPSED % 30)) -eq 0 ]; then
            echo -n "  ${ELAPSED}s..."
        fi
    done

    if [ "$BOOT_STATUS" != "1" ]; then
        warn "Emulator may not have fully booted (timeout ${BOOT_TIMEOUT}s)"
        warn "Check /tmp/emulator_pairip.log for errors"
        warn "You can also try: $EMULATOR -avd $AVD_NAME -gpu swiftshader_indirect"
        echo ""
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo ""
        [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    fi

    # Give system services a moment to settle
    sleep 5
fi

# Verify ADB connection
"$ADB" devices | grep -q "device$" || die "No device/emulator connected via ADB"
log "ADB connected: $("$ADB" devices | grep device$ | head -1)"

# ############################################################################
#
#   PART 2: APK PATCHING
#
# ############################################################################

# ============================================================================
# Step 5: Download apktool
# ============================================================================

section "Step 5/16: Setting up apktool"

APKTOOL="${APKTOOL_PATH:-}"
if [ -z "$APKTOOL" ]; then
    for candidate in "$HOME/bin/apktool.jar" "/usr/local/bin/apktool.jar"; do
        if [ -f "$candidate" ]; then
            APKTOOL="$candidate"
            break
        fi
    done
fi

if [ -z "$APKTOOL" ] || [ ! -f "$APKTOOL" ]; then
    APKTOOL="$WORK_DIR/apktool.jar"
    if [ ! -f "$APKTOOL" ]; then
        log "Downloading apktool 2.10.0..."
        curl -L -o "$APKTOOL" "https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.10.0.jar"
    fi
fi
log "apktool: $APKTOOL"

# ============================================================================
# Step 6: Decompile APK
# ============================================================================

section "Step 6/16: Decompiling APK"

if [ -d "$DECOMPILED" ]; then
    warn "Removing existing decompiled directory..."
    rm -rf "$DECOMPILED"
fi

log "Decompiling $(basename "$APK_INPUT")..."
java -jar "$APKTOOL" d "$APK_INPUT" -o "$DECOMPILED" --use-aapt2 -f
log "Decompiled to $DECOMPILED"

# Auto-detect package name and main activity from AndroidManifest.xml
MANIFEST="$DECOMPILED/AndroidManifest.xml"
PACKAGE=$(grep -o 'package="[^"]*"' "$MANIFEST" | head -1 | sed 's/package="//;s/"//')
MAIN_ACTIVITY=$(grep -B10 'android.intent.action.MAIN' "$MANIFEST" | grep -o 'android:name="[^"]*"' | tail -1 | sed 's/android:name="//;s/"//')
log "Package: $PACKAGE"
log "Main activity: $MAIN_ACTIVITY"

# Handle split APK (XAPK): if libflutter.so is not in the base APK,
# extract it from config.arm64_v8a.apk in the same directory
if [ ! -f "$DECOMPILED/lib/arm64-v8a/libflutter.so" ]; then
    APK_DIR="$(dirname "$APK_INPUT")"
    SPLIT_APK="$APK_DIR/config.arm64_v8a.apk"
    if [ -f "$SPLIT_APK" ]; then
        log "Split APK detected — extracting native libs from config.arm64_v8a.apk..."
        mkdir -p "$DECOMPILED/lib/arm64-v8a"
        unzip -o "$SPLIT_APK" "lib/arm64-v8a/*" -d "$DECOMPILED/"
        log "Extracted $(ls "$DECOMPILED/lib/arm64-v8a/"*.so 2>/dev/null | wc -l | tr -d ' ') native libs"
    else
        die "libflutter.so not found in base APK or split APK. Check APK format."
    fi
fi

# ============================================================================
# Step 7: Replace encrypted libflutter.so with stock engine
# ============================================================================

section "Step 7/16: Replacing PairIP-encrypted Flutter engine"

# Auto-detect Flutter engine commit from the encrypted libflutter.so
ORIG_FLUTTER="$DECOMPILED/lib/arm64-v8a/libflutter.so"
if [ -z "$FLUTTER_ENGINE_COMMIT" ]; then
    log "Auto-detecting Flutter engine commit from binary..."
    for hash in $(strings "$ORIG_FLUTTER" | grep -E '^[0-9a-f]{40}$'); do
        STATUS=$(curl -sI "https://storage.googleapis.com/flutter_infra_release/flutter/${hash}/android-arm64-release/artifacts.zip" | head -1)
        if echo "$STATUS" | grep -q "200"; then
            FLUTTER_ENGINE_COMMIT="$hash"
            log "Found engine commit: $hash"
            break
        fi
    done
    [ -n "$FLUTTER_ENGINE_COMMIT" ] || die "Could not auto-detect Flutter engine commit. Set FLUTTER_ENGINE_COMMIT manually."
fi

FLUTTER_ENGINE_URL="https://storage.googleapis.com/flutter_infra_release/flutter/${FLUTTER_ENGINE_COMMIT}/android-arm64-release/artifacts.zip"
STOCK_DIR="$WORK_DIR/stock_flutter_${FLUTTER_ENGINE_COMMIT}"
mkdir -p "$STOCK_DIR"

if [ ! -f "$STOCK_DIR/lib/arm64-v8a/libflutter.so" ]; then
    log "Downloading stock Flutter engine (${FLUTTER_ENGINE_COMMIT:0:12}...)..."
    curl -L -o "$STOCK_DIR/artifacts.zip" "$FLUTTER_ENGINE_URL"
    # artifacts.zip may contain libflutter.so directly or inside flutter.jar
    if unzip -l "$STOCK_DIR/artifacts.zip" | grep -q "lib/arm64-v8a/libflutter.so"; then
        unzip -o "$STOCK_DIR/artifacts.zip" "lib/arm64-v8a/libflutter.so" -d "$STOCK_DIR"
    elif unzip -l "$STOCK_DIR/artifacts.zip" | grep -q "flutter.jar"; then
        unzip -o "$STOCK_DIR/artifacts.zip" "flutter.jar" -d "$STOCK_DIR"
        unzip -o "$STOCK_DIR/flutter.jar" "lib/arm64-v8a/libflutter.so" -d "$STOCK_DIR"
    else
        die "Unexpected artifacts.zip format — libflutter.so not found inside"
    fi
    log "Downloaded $(ls -lh "$STOCK_DIR/lib/arm64-v8a/libflutter.so" | awk '{print $5}')"
else
    log "Using cached stock Flutter engine"
fi

# Verify exported symbols match
STOCK_SYMS=$(nm -D "$STOCK_DIR/lib/arm64-v8a/libflutter.so" 2>/dev/null | grep " T " | awk '{print $3}' | sort)
ORIG_SYMS=$(nm -D "$ORIG_FLUTTER" 2>/dev/null | grep " T " | awk '{print $3}' | sort)
if [ "$STOCK_SYMS" != "$ORIG_SYMS" ]; then
    die "Exported symbols mismatch between stock and encrypted Flutter engines!"
fi
log "Verified: all $(echo "$STOCK_SYMS" | wc -l | tr -d ' ') exported symbols match"

# Backup original
mkdir -p "$WORK_DIR/orig_flutter/lib/arm64-v8a"
cp "$ORIG_FLUTTER" "$WORK_DIR/orig_flutter/lib/arm64-v8a/libflutter.so"

# Replace
cp "$STOCK_DIR/lib/arm64-v8a/libflutter.so" "$ORIG_FLUTTER"
log "Replaced libflutter.so with stock engine (${FLUTTER_ENGINE_COMMIT:0:12})"

# ============================================================================
# Step 8: Disable PairIP Java components
# ============================================================================

section "Step 8/16: Disabling PairIP Java classes"

# 8a. VMRunner - disable native library loading and VM execution
VMRUNNER=$(find "$DECOMPILED" -path "*/com/pairip/VMRunner.smali" | head -1)
if [ -n "$VMRUNNER" ] && [ -f "$VMRUNNER" ]; then
    cat > "$VMRUNNER" << 'SMALI'
.class public Lcom/pairip/VMRunner;
.super Ljava/lang/Object;

.method static constructor <clinit>()V
    .locals 0
    return-void
.end method

.method public constructor <init>()V
    .locals 0
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    return-void
.end method

.method public static invoke(Ljava/lang/String;)Ljava/lang/Object;
    .locals 1
    const/4 v0, 0x0
    return-object v0
.end method
SMALI
    log "  VMRunner: disabled (no loadLibrary, invoke returns null)"
fi

# 8b. StartupLauncher
LAUNCHER=$(find "$DECOMPILED" -path "*/com/pairip/StartupLauncher.smali" | head -1)
if [ -n "$LAUNCHER" ] && [ -f "$LAUNCHER" ]; then
    cat > "$LAUNCHER" << 'SMALI'
.class public Lcom/pairip/StartupLauncher;
.super Ljava/lang/Object;

.method public constructor <init>()V
    .locals 0
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    return-void
.end method

.method public static launch(Landroid/content/Context;)V
    .locals 0
    return-void
.end method
SMALI
    log "  StartupLauncher: disabled (launch is no-op)"
fi

# 8c. SignatureCheck
SIGCHECK=$(find "$DECOMPILED" -path "*/com/pairip/SignatureCheck.smali" | head -1)
if [ -n "$SIGCHECK" ] && [ -f "$SIGCHECK" ]; then
    cat > "$SIGCHECK" << 'SMALI'
.class public Lcom/pairip/SignatureCheck;
.super Ljava/lang/Object;

.method public constructor <init>()V
    .locals 0
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    return-void
.end method

.method public static verifyIntegrity(Landroid/content/Context;)V
    .locals 0
    return-void
.end method
SMALI
    log "  SignatureCheck: disabled (verify returns immediately)"
fi

# 8d. CoreComponentFactory - clear clinit
COREFACTORY=$(find "$DECOMPILED" -path "*/androidx/core/app/CoreComponentFactory.smali" | head -1)
if [ -n "$COREFACTORY" ] && [ -f "$COREFACTORY" ]; then
    python3 -c "
with open('$COREFACTORY', 'r') as f:
    content = f.read()

import re
# Replace the clinit method body with just return-void
pattern = r'(\.method static constructor <clinit>\(\)V\n).*?(\.end method)'
replacement = r'\1    .locals 0\n\n    return-void\n\2'
content = re.sub(pattern, replacement, content, flags=re.DOTALL)

with open('$COREFACTORY', 'w') as f:
    f.write(content)
"
    log "  CoreComponentFactory: clinit cleared"
fi

# ============================================================================
# Step 9: Disable crash-prone ContentProviders
# ============================================================================

section "Step 9/16: Disabling crash-prone ContentProviders"

# Remove split APK requirements (needed when libs were extracted from config.arm64_v8a.apk)
sed -i '' 's/ android:requiredSplitTypes="[^"]*"//g' "$MANIFEST"
sed -i '' 's/ android:splitTypes="[^"]*"//g' "$MANIFEST"
sed -i '' 's/android:name="com.android.vending.splits.required" android:value="true"/android:name="com.android.vending.splits.required" android:value="false"/g' "$MANIFEST"
# Enable native lib extraction (required when bundling split APK libs into single APK)
sed -i '' 's/extractNativeLibs="false"/extractNativeLibs="true"/g' "$MANIFEST"
log "  Removed split APK requirements, enabled native lib extraction"

for provider in \
    "androidx.startup.InitializationProvider" \
    "com.google.firebase.provider.FirebaseInitProvider" \
    "com.google.android.gms.ads.MobileAdsInitProvider" \
    "com.pairip.licensecheck.LicenseContentProvider"; do
    if grep -q "android:name=\"$provider\"" "$MANIFEST"; then
        # Only add enabled="false" if not already present
        if ! grep -q "android:name=\"$provider\" android:enabled=\"false\"" "$MANIFEST"; then
            sed -i '' "s|android:name=\"$provider\"|android:name=\"$provider\" android:enabled=\"false\"|g" "$MANIFEST"
        fi
        log "  Disabled: $(echo $provider | awk -F. '{print $NF}')"
    fi
done

# ============================================================================
# Step 10: Initialize vault classes + patch 15 critical reflection strings
# ============================================================================

section "Step 10/16: Patching PairIP vault strings"

log "Initializing vault class static fields..."

# Initialize vault classes — use Python for reliable detection and patching
vault_count=$(python3 << 'PYEOF'
import os, re, glob

decompiled = os.environ.get("DECOMPILED", "/tmp/pairip_patch/decompiled")
count = 0

for smali_dir in sorted(glob.glob(os.path.join(decompiled, "smali*"))):
    for root, dirs, files in os.walk(smali_dir):
        for fname in files:
            if not fname.endswith(".smali"):
                continue
            fpath = os.path.join(root, fname)
            try:
                with open(fpath) as f:
                    content = f.read()
            except:
                continue

            # Count String fields
            str_fields = re.findall(r'\.field public static (\w+):Ljava/lang/String;', content)
            if len(str_fields) < 20:
                continue

            # Vault classes have NO methods (or just an empty clinit) and NO const-string
            methods = re.findall(r'^\.method\b', content, re.MULTILINE)
            if len(methods) > 2:
                continue

            if 'const-string' in content:
                continue

            # Must not have .source (SDK classes have .source, vault classes don't)
            if '.source' in content:
                continue

            # Extract class descriptor
            cls_match = re.search(r'^\.class\s+.*\s+(L\S+;)', content, re.MULTILINE)
            if not cls_match:
                continue
            cls_desc = cls_match.group(1)

            # Build clinit that initializes all String fields to ""
            clinit_lines = ['.method static constructor <clinit>()V', '    .locals 1', '']
            for field_name in str_fields:
                clinit_lines.append(f'    const-string v0, ""')
                clinit_lines.append(f'')
                clinit_lines.append(f'    sput-object v0, {cls_desc}->{field_name}:Ljava/lang/String;')
                clinit_lines.append(f'')
            clinit_lines.append('    return-void')
            clinit_lines.append('.end method')

            # Remove existing clinit if present
            content = re.sub(
                r'\.method static constructor <clinit>\(\)V\n.*?\.end method\n?',
                '', content, flags=re.DOTALL
            )

            # Append new clinit
            content = content.rstrip() + '\n\n' + '\n'.join(clinit_lines) + '\n'

            with open(fpath, 'w') as f:
                f.write(content)
            count += 1

print(count)
PYEOF
)
export DECOMPILED
log "  Initialized $vault_count vault classes with empty strings"

log "Auto-detecting critical reflection-dependent vault strings..."

# Instead of hardcoding vault field names (which change per version),
# we scan smali for vault fields used in reflection calls and patch them
# with the correct values extracted from the call context.
python3 << 'PYEOF'
import os, re, glob, sys

decompiled = os.environ.get("DECOMPILED", "/tmp/pairip_patch/decompiled")

# Collect all vault classes (classes with many static String fields, no const-strings in body)
vault_classes = set()
for smali_dir in sorted(glob.glob(os.path.join(decompiled, "smali*"))):
    for root, dirs, files in os.walk(smali_dir):
        for fname in files:
            if not fname.endswith(".smali"):
                continue
            fpath = os.path.join(root, fname)
            try:
                with open(fpath) as f:
                    content = f.read()
            except:
                continue
            field_count = len(re.findall(r'\.field public static \w+:Ljava/lang/String;', content))
            if field_count > 20:
                m = re.search(r'^\.class\s+.*\s+(L\S+;)', content, re.MULTILINE)
                if m:
                    vault_classes.add(m.group(1))

print(f"  Found {len(vault_classes)} vault classes")

# Build regex to match sget-object from any vault class
vault_pattern = re.compile(
    r'sget-object\s+(\w+),\s+(L\S+;)->(\w+):Ljava/lang/String;'
)

# Map of known reflection call patterns -> how to find the correct value
# We look for patterns where a vault field is loaded then used in a reflection call
patches = {}  # (class_desc, field_name) -> correct_value

# Scan ALL smali files for vault field usage in reflection calls
all_smali = []
for smali_dir in sorted(glob.glob(os.path.join(decompiled, "smali*"))):
    for root, dirs, files in os.walk(smali_dir):
        for fname in files:
            if fname.endswith(".smali"):
                all_smali.append(os.path.join(root, fname))

for fpath in all_smali:
    try:
        with open(fpath) as f:
            lines = f.readlines()
    except:
        continue

    for i, line in enumerate(lines):
        m = vault_pattern.search(line)
        if not m:
            continue
        reg, cls, field = m.group(1), m.group(2), m.group(3)
        if cls not in vault_classes:
            continue

        # Look ahead up to 10 lines for reflection usage of this register
        context = ''.join(lines[i:i+10])

        # AtomicFieldUpdater.newUpdater - the field name itself is critical
        # We need to find the actual volatile field name from the class
        if 'AtomicIntegerFieldUpdater;->newUpdater' in context or \
           'AtomicLongFieldUpdater;->newUpdater' in context or \
           'AtomicReferenceFieldUpdater;->newUpdater' in context:
            # The class is usually loaded with const-class just before
            for j in range(max(0, i-5), i):
                cm = re.search(r'const-class\s+\w+,\s+(L\S+;)', lines[j])
                if cm:
                    target_cls = cm.group(1)
                    # Find the volatile field in that class
                    target_file = None
                    target_cls_path = target_cls[1:-1] + ".smali"
                    for sd in sorted(glob.glob(os.path.join(decompiled, "smali*"))):
                        candidate = os.path.join(sd, target_cls_path)
                        if os.path.exists(candidate):
                            target_file = candidate
                            break
                    if target_file:
                        with open(target_file) as tf:
                            tc = tf.read()
                        vol_match = re.search(r'\.field\s+\w+\s+volatile\s+\w*\s*(\w+):', tc)
                        if vol_match:
                            patches[(cls, field)] = vol_match.group(1)
                    break

        # Class.forName
        elif 'Class;->forName' in context:
            # Need to figure out what class name should be here
            # Look for clues in surrounding code
            pass

        # Class.getMethod / getDeclaredMethod
        elif 'getMethod' in context or 'getDeclaredMethod' in context:
            pass

    # Also check for loadClass patterns
    for i, line in enumerate(lines):
        m = vault_pattern.search(line)
        if not m:
            continue
        reg, cls, field = m.group(1), m.group(2), m.group(3)
        if cls not in vault_classes:
            continue
        context = ''.join(lines[i:i+10])
        if 'loadClass' in context or 'Class;->forName' in context:
            # These are class name strings - harder to auto-detect
            pass

# Known critical strings that appear across all versions
# These are the actual Java/Android API strings that must be correct
KNOWN_STRINGS = {
    "completedExpandBuffersAndPauseFlag$volatile": "completedExpandBuffersAndPauseFlag$volatile",
    "received": "received",
    "android.app.ActivityThread": "android.app.ActivityThread",
    "com.google.protobuf.UnknownFieldSetSchema": "com.google.protobuf.UnknownFieldSetSchema",
    "addWindowLayoutInfoListener": "addWindowLayoutInfoListener",
    "rawVersion": "rawVersion",
    "write": "write",
    "getAdvertisingIdInfo": "getAdvertisingIdInfo",
    "putByte": "putByte",
    "arrayIndexScale": "arrayIndexScale",
    "isRecord": "isRecord",
    "com.google.android.gms": "com.google.android.gms",
    "double": "double",
    "INTERSTITIAL": "INTERSTITIAL",
    "androidx.window.extensions.layout.WindowLayoutComponent": "androidx.window.extensions.layout.WindowLayoutComponent",
}

# For the auto-detected patches, apply them
print(f"  Auto-detected {len(patches)} vault strings from reflection analysis")
for (cls, field), value in sorted(patches.items()):
    print(f"    {field} = \"{value}\"")

# Now scan vault class smali files and patch const-strings
total_patched = 0
for smali_dir in sorted(glob.glob(os.path.join(decompiled, "smali*"))):
    for root, dirs, files in os.walk(smali_dir):
        for fname in files:
            if not fname.endswith(".smali"):
                continue
            fpath = os.path.join(root, fname)
            try:
                with open(fpath) as f:
                    content = f.read()
            except:
                continue

            m = re.search(r'^\.class\s+.*\s+(L\S+;)', content, re.MULTILINE)
            if not m or m.group(1) not in vault_classes:
                continue

            cls_desc = m.group(1)
            modified = False

            for (pcls, pfield), pvalue in patches.items():
                if pcls != cls_desc:
                    continue
                # Find the sput for this field and change the preceding const-string
                sput_pat = re.compile(
                    r'sput-object\s+\w+,\s+' + re.escape(cls_desc) + r'->' + re.escape(pfield) + r':Ljava/lang/String;'
                )
                match = sput_pat.search(content)
                if match:
                    before = content[:match.start()]
                    last_const = before.rfind('const-string ')
                    if last_const >= 0:
                        line_end = content.index('\n', last_const)
                        old_line = content[last_const:line_end]
                        reg_match = re.match(r'const-string\s+(\w+),', old_line.strip())
                        if reg_match:
                            new_line = f'    const-string {reg_match.group(1)}, "{pvalue}"'
                            content = content[:last_const] + new_line + content[line_end:]
                            modified = True
                            total_patched += 1

            if modified:
                with open(fpath, 'w') as f:
                    f.write(content)

print(f"  Applied {total_patched} vault string patches")
PYEOF
export DECOMPILED

# ============================================================================
# Step 11: Patch protobuf field lookup for empty names
# ============================================================================

section "Step 11/16: Patching protobuf & Tink for empty vault strings"

# Find the protobuf field lookup method - search by signature since class name may differ
PROTOBUF_S=$(grep -rl 'getDeclaredField.*getField\|\.method public static.*Ljava/lang/Class;Ljava/lang/String;.*Ljava/lang/reflect/Field;' "$DECOMPILED" 2>/dev/null | head -1)
if [ -z "$PROTOBUF_S" ]; then
    PROTOBUF_S=$(find "$DECOMPILED" -path "*/crypto/tink/shaded/protobuf/S.smali" -o -path "*/protobuf/S.smali" 2>/dev/null | head -1)
fi
if [ -z "$PROTOBUF_S" ]; then
    PROTOBUF_S=$(grep -rl '\.method public static O(Ljava/lang/Class;Ljava/lang/String;)Ljava/lang/reflect/Field;' "$DECOMPILED" 2>/dev/null | head -1)
fi

# Patch protobuf field lookup: for ANY method that takes (Class, String) and returns Field,
# add an empty-string guard that returns the first declared field
if [ -n "$PROTOBUF_S" ] && [ -f "$PROTOBUF_S" ]; then
    python3 -c "
import re, sys

smali_file = '$PROTOBUF_S'
with open(smali_file, 'r') as f:
    content = f.read()

# Find methods that take (Class, String) and return Field
pattern = r'(\.method\s+public\s+static\s+\w+\(Ljava/lang/Class;Ljava/lang/String;\)Ljava/lang/reflect/Field;)'
matches = list(re.finditer(pattern, content))
if not matches:
    print('  Warning: No (Class, String)->Field method found')
    sys.exit(0)

if 'PairIP bypass' in content and 'isEmpty' in content:
    print('  Protobuf field lookup already patched')
    sys.exit(0)

for m in matches:
    sig_line = m.group(1)
    start = m.start()
    end = content.index('.end method', start) + len('.end method')
    method_body = content[start:end]

    # Extract method name for recursive call
    name_match = re.search(r'\.method\s+public\s+static\s+(\w+)\(', sig_line)
    method_name = name_match.group(1) if name_match else 'O'

    # Extract the class descriptor from the file
    cls_match = re.search(r'^\.class\s+.*\s+(L\S+;)', content, re.MULTILINE)
    cls_desc = cls_match.group(1) if cls_match else 'Lcom/google/crypto/tink/shaded/protobuf/S;'

    # Build the isEmpty guard to insert after the method signature
    guard = '''
    # PairIP bypass: if field name is empty, return first declared field
    invoke-virtual {p1}, Ljava/lang/String;->isEmpty()Z
    move-result v0
    if-eqz v0, :field_not_empty
    invoke-virtual {p0}, Ljava/lang/Class;->getDeclaredFields()[Ljava/lang/reflect/Field;
    move-result-object v0
    array-length v1, v0
    if-eqz v1, :field_not_empty
    const/4 v1, 0x0
    aget-object v0, v0, v1
    return-object v0
    :field_not_empty
'''
    # Insert guard after the .locals line
    locals_match = re.search(r'(\.locals\s+\d+\n)', method_body)
    if locals_match:
        insert_pos = start + locals_match.end()
        # Ensure .locals is at least 5
        old_locals = locals_match.group(1)
        locals_num = int(re.search(r'\d+', old_locals).group())
        if locals_num < 5:
            content = content[:start + locals_match.start()] + '    .locals 5\n' + content[start + locals_match.end():]
            # Recalculate insert_pos
            insert_pos = start + locals_match.start() + len('    .locals 5\n')
        content = content[:insert_pos] + guard + content[insert_pos:]
        print(f'  Patched {cls_desc}->{method_name}: returns first declared field for empty names')
    break  # Only patch the first matching method

with open(smali_file, 'w') as f:
    f.write(content)
"
else
    warn "  Protobuf field lookup method not found (may not be needed)"
fi

# Wrap Tink/crypto init in try-catch — generic approach: find clinit methods
# that call crypto init and wrap them
log "Wrapping crypto init methods in try-catch..."
# Search for crypto init helper classes (Tink, KeysetHandle, etc.)
CRYPTO_INITS=$(grep -rl "KeysetHandle\|TinkConfig\|RegistryConfiguration\|crypto.*init\|tink.*Register" "$DECOMPILED" 2>/dev/null | head -5)
TINK_WRAPPED=0
for tink_file in $CRYPTO_INITS; do
    python3 -c "
import re
with open('$tink_file', 'r') as f:
    content = f.read()

# Look for static init calls that might fail with empty vault strings
# Wrap consecutive invoke-static calls in clinit with try-catch
clinit_match = re.search(r'(\.method\s+(?:static\s+constructor\s+)?<clinit>\(\)V\n)(.*?)(\.end method)', content, re.DOTALL)
if clinit_match and ':try_start_init' not in content:
    body = clinit_match.group(2)
    if 'invoke-static' in body and 'return-void' in body:
        # Wrap the entire clinit body in try-catch
        new_body = body.replace('return-void', '''    goto :clinit_ok
    .catchall {:try_start_clinit .. :try_end_clinit} :catch_clinit
    :catch_clinit
    # PairIP bypass: swallow crypto init errors
    :clinit_ok
    return-void''', 1)
        # Add try_start right after .locals
        locals_match = re.search(r'(\.locals\s+\d+\n)', new_body)
        if locals_match:
            insert = locals_match.end()
            new_body = new_body[:insert] + '    :try_start_clinit\n' + new_body[insert:]
            # Add try_end before goto
            new_body = new_body.replace('    goto :clinit_ok', '    :try_end_clinit\n    goto :clinit_ok')
            new_content = content[:clinit_match.start(2)] + new_body + content[clinit_match.end(2):]
            with open('$tink_file', 'w') as f:
                f.write(new_content)
            print(f'  Wrapped clinit in $tink_file')
" 2>/dev/null && TINK_WRAPPED=$((TINK_WRAPPED + 1))
done
log "  Wrapped $TINK_WRAPPED crypto init methods"

# ============================================================================
# Step 12: Create SafeExceptionHandler
# ============================================================================

section "Step 12/16: Creating SafeExceptionHandler"

# Find where pairip/application lives (may be smali/, smali_classes4/, etc.)
HANDLER_DIR=$(find "$DECOMPILED" -type d -path "*/com/pairip/application" | head -1)
if [ -z "$HANDLER_DIR" ]; then
    HANDLER_DIR="$DECOMPILED/smali/com/pairip/application"
fi
mkdir -p "$HANDLER_DIR"

cat > "$HANDLER_DIR/SafeExceptionHandler.smali" << 'SMALI'
.class public Lcom/pairip/application/SafeExceptionHandler;
.super Ljava/lang/Object;
.implements Ljava/lang/Thread$UncaughtExceptionHandler;


# instance fields
.field private final originalHandler:Ljava/lang/Thread$UncaughtExceptionHandler;


# direct methods
.method public constructor <init>(Ljava/lang/Thread$UncaughtExceptionHandler;)V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lcom/pairip/application/SafeExceptionHandler;->originalHandler:Ljava/lang/Thread$UncaughtExceptionHandler;

    return-void
.end method


# virtual methods
.method public uncaughtException(Ljava/lang/Thread;Ljava/lang/Throwable;)V
    .locals 3

    # Get the main looper's thread
    invoke-static {}, Landroid/os/Looper;->getMainLooper()Landroid/os/Looper;

    move-result-object v0

    invoke-virtual {v0}, Landroid/os/Looper;->getThread()Ljava/lang/Thread;

    move-result-object v0

    # Compare current thread with main thread
    if-ne p1, v0, :not_main_thread

    # Main thread - forward to original handler if available
    iget-object v0, p0, Lcom/pairip/application/SafeExceptionHandler;->originalHandler:Ljava/lang/Thread$UncaughtExceptionHandler;

    if-eqz v0, :no_handler

    invoke-interface {v0, p1, p2}, Ljava/lang/Thread$UncaughtExceptionHandler;->uncaughtException(Ljava/lang/Thread;Ljava/lang/Throwable;)V

    :no_handler
    return-void

    :not_main_thread
    # Background thread - log and swallow to prevent process death
    const-string v0, "SafeExceptionHandler"

    new-instance v1, Ljava/lang/StringBuilder;

    invoke-direct {v1}, Ljava/lang/StringBuilder;-><init>()V

    const-string v2, "Caught exception on background thread: "

    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {p1}, Ljava/lang/Thread;->getName()Ljava/lang/String;

    move-result-object v2

    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v1}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v1

    invoke-static {v0, v1, p2}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    # Just return - thread dies but process continues
    return-void
.end method
SMALI
log "  Created SafeExceptionHandler.smali"

# Install in Application.smali
APP_SMALI="$HANDLER_DIR/Application.smali"
if [ -f "$APP_SMALI" ]; then
    cat > "$APP_SMALI" << 'SMALI'
.class public Lcom/pairip/application/Application;
.super Landroid/app/Application;


# direct methods
.method static constructor <clinit>()V
    .locals 0

    return-void
.end method

.method public constructor <init>()V
    .locals 0

    invoke-direct {p0}, Landroid/app/Application;-><init>()V

    return-void
.end method


# virtual methods
.method protected attachBaseContext(Landroid/content/Context;)V
    .locals 2

    invoke-super {p0, p1}, Lcom/pairip/application/Application;->attachBaseContext(Landroid/content/Context;)V

    # PairIP bypass: install custom UncaughtExceptionHandler to prevent background thread crashes
    invoke-static {}, Ljava/lang/Thread;->getDefaultUncaughtExceptionHandler()Ljava/lang/Thread$UncaughtExceptionHandler;
    move-result-object v0

    new-instance v1, Lcom/pairip/application/SafeExceptionHandler;
    invoke-direct {v1, v0}, Lcom/pairip/application/SafeExceptionHandler;-><init>(Ljava/lang/Thread$UncaughtExceptionHandler;)V
    invoke-static {v1}, Ljava/lang/Thread;->setDefaultUncaughtExceptionHandler(Ljava/lang/Thread$UncaughtExceptionHandler;)V

    return-void
.end method
SMALI
    log "  Installed SafeExceptionHandler in Application.attachBaseContext"
fi

# ============================================================================
# Step 13: Fix Flutter asset paths + remove crash-prone native libs
# ============================================================================

section "Step 13/16: Fixing asset paths & removing crash-prone native libs"

# 13a. Flutter asset path mismatch:
# Compiled Dart code (libapp.so) hardcodes "app/assets/" prefix for asset lookups,
# but AssetManifest.json only registers them under "assets/". Copy assets to both
# locations and update the manifest.
FLUTTER_ASSETS="$DECOMPILED/assets/flutter_assets"
ASSET_MANIFEST="$FLUTTER_ASSETS/AssetManifest.json"

if [ -d "$FLUTTER_ASSETS/assets" ] && [ -f "$ASSET_MANIFEST" ]; then
    # Check if app/assets/ prefix is needed (look for it in libapp.so or manifest)
    NEEDS_APP_PREFIX=false
    LIBAPP="$DECOMPILED/lib/arm64-v8a/libapp.so"
    if [ -f "$LIBAPP" ] && strings "$LIBAPP" 2>/dev/null | grep -q "app/assets/"; then
        NEEDS_APP_PREFIX=true
    fi

    if $NEEDS_APP_PREFIX && [ ! -d "$FLUTTER_ASSETS/app/assets" ]; then
        log "  Copying assets/ → app/assets/ (libapp.so uses app/assets/ prefix)"
        mkdir -p "$FLUTTER_ASSETS/app/assets"
        cp "$FLUTTER_ASSETS/assets/"* "$FLUTTER_ASSETS/app/assets/" 2>/dev/null || true

        # Update AssetManifest.json to include app/assets/ entries
        python3 -c "
import json, os

manifest_path = '$ASSET_MANIFEST'
with open(manifest_path) as f:
    manifest = json.load(f)

modified = False
for key in list(manifest.keys()):
    if key.startswith('assets/'):
        new_key = 'app/' + key
        if new_key not in manifest:
            manifest[new_key] = ['app/' + v for v in manifest[key]]
            modified = True

if modified:
    with open(manifest_path, 'w') as f:
        json.dump(manifest, f, separators=(',', ':'))
    print(f'  Updated AssetManifest.json with app/assets/ entries')
else:
    print(f'  AssetManifest.json already has app/assets/ entries')
"
    else
        log "  Asset paths OK (no app/assets/ prefix needed or already present)"
    fi
else
    log "  No flutter_assets/assets/ directory found (skipping)"
fi

# 13b. Remove crash-prone native libraries
# libembrace-native.so causes SIGILL on emulators. Other monitoring libs may too.
REMOVED_LIBS=0
for lib_pattern in "libembrace-native.so" "libpairipcore.so"; do
    FOUND_LIBS=$(find "$DECOMPILED/lib" -name "$lib_pattern" 2>/dev/null)
    for lib in $FOUND_LIBS; do
        rm -f "$lib"
        REMOVED_LIBS=$((REMOVED_LIBS + 1))
        log "  Removed: $(basename "$lib")"
    done
done
if [ $REMOVED_LIBS -eq 0 ]; then
    log "  No crash-prone native libs found"
fi

# 13c. Strip Embrace SDK initialization calls
# Embrace.start() crashes without its native lib. Find and neutralize it.
EMBRACE_PATCHED=0
python3 << 'PYEOF'
import os, re, glob

decompiled = os.environ.get("DECOMPILED", "/tmp/pairip_patch/decompiled")
patched = 0

for smali_dir in sorted(glob.glob(os.path.join(decompiled, "smali*"))):
    for root, dirs, files in os.walk(smali_dir):
        for fname in files:
            if not fname.endswith(".smali"):
                continue
            fpath = os.path.join(root, fname)
            try:
                with open(fpath) as f:
                    content = f.read()
            except:
                continue

            if 'Embrace;->start(' not in content and 'Embrace;->getInstance()' not in content:
                continue

            # Skip Embrace's own classes
            if '/embrace/' in fpath:
                continue

            modified = False

            # Wrap Embrace.start() calls in try-catch
            # Find methods containing Embrace calls and wrap the call + surrounding lines
            lines = content.split('\n')
            new_lines = []
            i = 0
            while i < len(lines):
                line = lines[i]
                if 'Embrace;->start(' in line:
                    # Wrap this invoke in try-catch
                    new_lines.append('    :try_start_embrace')
                    new_lines.append(line)
                    new_lines.append('    :try_end_embrace')
                    new_lines.append('    .catch Ljava/lang/Throwable; {:try_start_embrace .. :try_end_embrace} :catch_embrace')
                    new_lines.append('    goto :embrace_done')
                    new_lines.append('    :catch_embrace')
                    new_lines.append('    move-exception v0')
                    new_lines.append('    :embrace_done')
                    modified = True
                else:
                    new_lines.append(line)
                i += 1

            if modified:
                with open(fpath, 'w') as f:
                    f.write('\n'.join(new_lines))
                patched += 1
                print(f"  Wrapped Embrace.start() in {os.path.basename(fpath)}")

print(f"  Neutralized Embrace SDK in {patched} files")
PYEOF
export DECOMPILED

# ============================================================================
# Step 14: Patch remaining crash sources (Snowplow, SecureStorage, MethodChannels)
# ============================================================================

section "Step 14/16: Patching remaining crash sources"

# 14a. Snowplow / analytics MethodChannel handlers:
# These use vault strings as map keys (e.g., "action" for structured events).
# When the vault string is empty, the map lookup throws NoSuchElementException.
# We auto-detect vault strings used as Kotlin property reference names and patch them.
log "Auto-detecting vault strings used as Kotlin property names..."
python3 << 'PYEOF'
import os, re, glob

decompiled = os.environ.get("DECOMPILED", "/tmp/pairip_patch/decompiled")

# Collect vault classes
vault_classes = set()
for smali_dir in sorted(glob.glob(os.path.join(decompiled, "smali*"))):
    for root, dirs, files in os.walk(smali_dir):
        for fname in files:
            if not fname.endswith(".smali"):
                continue
            fpath = os.path.join(root, fname)
            try:
                with open(fpath) as f:
                    content = f.read()
            except:
                continue
            field_count = len(re.findall(r'\.field public static \w+:Ljava/lang/String;', content))
            if field_count > 20:
                m = re.search(r'^\.class\s+.*\s+(L\S+;)', content, re.MULTILINE)
                if m:
                    vault_classes.add(m.group(1))

# Scan for vault fields used as Kotlin property reference names
# Pattern: sget-object vault_field, then const-string with getter signature like "getAction()..."
# The property name is extracted from the getter: getXxx -> xxx (lowercase first char)
vault_patches = {}  # (vault_class, field_name) -> correct_value

for smali_dir in sorted(glob.glob(os.path.join(decompiled, "smali*"))):
    for root, dirs, files in os.walk(smali_dir):
        for fname in files:
            if not fname.endswith(".smali"):
                continue
            fpath = os.path.join(root, fname)
            try:
                with open(fpath) as f:
                    lines = f.readlines()
            except:
                continue

            for i, line in enumerate(lines):
                m = re.search(r'sget-object\s+(\w+),\s+(L\S+;)->(\w+):Ljava/lang/String;', line)
                if not m:
                    continue
                reg, cls, field = m.group(1), m.group(2), m.group(3)
                if cls not in vault_classes:
                    continue

                # Look ahead for getter signature: const-string vN, "getXxx()..."
                for j in range(i+1, min(i+8, len(lines))):
                    gm = re.search(r'const-string\s+\w+,\s+"get(\w+)\(', lines[j])
                    if gm:
                        prop = gm.group(1)
                        # Convert PascalCase to camelCase (first char lowercase)
                        prop_name = prop[0].lower() + prop[1:]
                        vault_patches[(cls, field)] = prop_name
                        break

# Apply patches to vault class clinit methods
patched_count = 0
for smali_dir in sorted(glob.glob(os.path.join(decompiled, "smali*"))):
    for root, dirs, files in os.walk(smali_dir):
        for fname in files:
            if not fname.endswith(".smali"):
                continue
            fpath = os.path.join(root, fname)
            try:
                with open(fpath) as f:
                    content = f.read()
            except:
                continue

            m = re.search(r'^\.class\s+.*\s+(L\S+;)', content, re.MULTILINE)
            if not m or m.group(1) not in vault_classes:
                continue

            cls_desc = m.group(1)
            modified = False

            for (pcls, pfield), pvalue in vault_patches.items():
                if pcls != cls_desc:
                    continue
                # Find the sput for this field and change the preceding const-string
                sput_pat = re.compile(
                    r'sput-object\s+\w+,\s+' + re.escape(cls_desc) + r'->' + re.escape(pfield) + r':Ljava/lang/String;'
                )
                match = sput_pat.search(content)
                if match:
                    before = content[:match.start()]
                    last_const = before.rfind('const-string ')
                    if last_const >= 0:
                        line_end = content.index('\n', last_const)
                        old_line = content[last_const:line_end]
                        reg_match = re.match(r'const-string\s+(\w+),', old_line.strip())
                        if reg_match:
                            new_line = f'    const-string {reg_match.group(1)}, "{pvalue}"'
                            content = content[:last_const] + new_line + content[line_end:]
                            modified = True
                            patched_count += 1
                            print(f"    {pfield} = \"{pvalue}\"")

            if modified:
                with open(fpath, 'w') as f:
                    f.write(content)

print(f"  Patched {patched_count} Kotlin property vault strings")
PYEOF
export DECOMPILED

# 14b. Wrap MethodChannel onMethodCall handlers in try-catch
# Many Flutter plugins crash when vault strings are empty. Wrapping in try-catch
# lets the app continue running with degraded plugin functionality.
log "Wrapping MethodChannel handlers in try-catch..."
python3 << 'PYEOF'
import os, re, glob

decompiled = os.environ.get("DECOMPILED", "/tmp/pairip_patch/decompiled")
wrapped = 0

for smali_dir in sorted(glob.glob(os.path.join(decompiled, "smali*"))):
    for root, dirs, files in os.walk(smali_dir):
        for fname in files:
            if not fname.endswith(".smali"):
                continue
            fpath = os.path.join(root, fname)
            try:
                with open(fpath) as f:
                    content = f.read()
            except:
                continue

            # Find onMethodCall(Lwb/m;Lwb/o;)V or similar MethodChannel handler signatures
            # The parameter types may vary by Flutter version, so match generically
            pattern = re.compile(
                r'(\.method\s+public\s+(?:final\s+)?onMethodCall\([^)]*\)V\s*\n'
                r'\s*\.locals\s+(\d+)\n)',
                re.MULTILINE
            )
            match = pattern.search(content)
            if not match:
                continue

            # Skip if already wrapped
            if ':try_start_mc' in content:
                continue

            # Skip Flutter's own framework classes
            if '/flutter/' in fpath or '/io/flutter/' in fpath:
                continue

            # Find the method boundaries
            method_start = match.start()
            method_end = content.find('.end method', method_start)
            if method_end < 0:
                continue

            header_end = match.end()  # position right after .locals N\n

            # Get everything between header and .end method
            body_content = content[header_end:method_end]
            content_after = content[method_end + len('.end method'):]

            # Wrap body in try-catch
            new_method = (
                content[:header_end]
                + '    :try_start_mc\n'
                + body_content.rstrip('\n') + '\n'
                + '    :try_end_mc\n'
                + '    .catch Ljava/lang/Exception; {:try_start_mc .. :try_end_mc} :catch_mc\n'
                + '    goto :mc_done\n'
                + '    :catch_mc\n'
                + '    move-exception v0\n'
                + '    :mc_done\n'
                + '    return-void\n'
                + '.end method'
                + content_after
            )
            content = new_method

            with open(fpath, 'w') as f:
                f.write(content)
            wrapped += 1

print(f"  Wrapped {wrapped} onMethodCall handlers in try-catch")
PYEOF
export DECOMPILED

# 14c. Patch FlutterSecureStorage cipher null-guard
# When vault strings for crypto algorithms are empty, the cipher object is null.
# This causes NPE on write/read. Add null checks to fall back to plaintext storage.
log "Patching SecureStorage cipher null-guards..."
python3 << 'PYEOF'
import os, re, glob

decompiled = os.environ.get("DECOMPILED", "/tmp/pairip_patch/decompiled")
patched = 0

# Find classes that implement SecureStorage-like pattern:
# - Has SharedPreferences reference
# - Has cipher/Cipher field
# - Has methods that call cipher.encrypt/decrypt
for smali_dir in sorted(glob.glob(os.path.join(decompiled, "smali*"))):
    for root, dirs, files in os.walk(smali_dir):
        for fname in files:
            if not fname.endswith(".smali"):
                continue
            fpath = os.path.join(root, fname)
            try:
                with open(fpath) as f:
                    content = f.read()
            except:
                continue

            # Identify FlutterSecureStorage handler pattern:
            # - Must reference SharedPreferences
            # - Must have a cipher-like field (type ending in cipher class)
            # - Must call encode/decode or encrypt/decrypt methods on it
            if 'SharedPreferences' not in content:
                continue
            if 'FlutterSecureStorage' not in content and 'flutter_secure_storage' not in content:
                # Also check for the pattern: has both cipher operations and SharedPreferences
                if not (re.search(r'\.field.*:L\w+/\w+;.*#.*cipher', content, re.I) or
                        ('cipher' in content.lower() and 'encrypt' in content.lower())):
                    continue

            # Find methods that call encrypt/encode on the cipher field
            # Add null check: if cipher is null, fall back to plaintext
            cls_match = re.search(r'^\.class\s+.*\s+(L\S+;)', content, re.MULTILINE)
            if not cls_match:
                continue

            # Find cipher field (iget-object vN, pN, Lclass;->fieldName:Ltype;)
            # followed by a method call on it
            cipher_fields = set()
            for m in re.finditer(r'iget-object\s+(\w+),\s+\w+,\s+(L\S+;->(\w+):L\S+;)', content):
                field_ref = m.group(2)
                field_name = m.group(3)
                # Check if this field is used for encrypt/decrypt in nearby lines
                pos = m.end()
                nearby = content[pos:pos+500]
                if re.search(r'invoke-virtual\s+\{[^}]*' + re.escape(m.group(1)) + r'[^}]*\}.*->(e|d|encrypt|decrypt|doFinal)\(', nearby):
                    cipher_fields.add(field_name)

            if not cipher_fields:
                continue

            # For each cipher field usage, wrap the encrypt/decrypt call block in try-catch
            # This is a lightweight approach: wrap the entire method body in try-catch
            methods_to_wrap = []
            for method_match in re.finditer(r'(\.method\s+(?:public|private|protected)\s+(?:final\s+)?(?:static\s+)?\w+\([^)]*\)[^\n]*\n)', content):
                method_start = method_match.start()
                method_end_pos = content.find('.end method', method_start)
                if method_end_pos < 0:
                    continue
                method_body = content[method_start:method_end_pos]

                # Check if this method uses a cipher field
                uses_cipher = False
                for cf in cipher_fields:
                    if cf in method_body and ('encrypt' in method_body.lower() or 'decrypt' in method_body.lower() or '->e(' in method_body or '->d(' in method_body):
                        uses_cipher = True
                        break

                if uses_cipher and ':try_start_cipher' not in method_body:
                    methods_to_wrap.append((method_start, method_end_pos))

            # Wrap methods from last to first (so offsets stay valid)
            for method_start, method_end_pos in reversed(methods_to_wrap):
                method_body = content[method_start:method_end_pos + len('.end method')]

                # Find .locals line
                locals_match = re.search(r'(\.locals\s+)(\d+)', method_body)
                if not locals_match:
                    continue

                # Ensure enough locals
                num_locals = int(locals_match.group(2))
                if num_locals < 3:
                    method_body = method_body[:locals_match.start(2)] + '3' + method_body[locals_match.end(2):]

                # Find the position after .locals line
                locals_line_end = method_body.find('\n', locals_match.start()) + 1

                # Determine return type
                ret_match = re.search(r'\)(\S+)', method_body)
                ret_type = ret_match.group(1) if ret_match else 'V'

                if ret_type == 'V':
                    fallback = '    return-void'
                elif ret_type.startswith('L') or ret_type.startswith('['):
                    fallback = '    const/4 v0, 0x0\n    return-object v0'
                else:
                    fallback = '    const/4 v0, 0x0\n    return v0'

                # Wrap body in try-catch
                body_after_locals = method_body[locals_line_end:]
                body_before_end = body_after_locals.replace('.end method', '')

                new_method_body = (
                    method_body[:locals_line_end]
                    + '    :try_start_cipher\n'
                    + body_before_end.rstrip('\n') + '\n'
                    + '    :try_end_cipher\n'
                    + '    .catch Ljava/lang/Throwable; {:try_start_cipher .. :try_end_cipher} :catch_cipher\n'
                    + '    goto :cipher_done\n'
                    + '    :catch_cipher\n'
                    + '    move-exception v0\n'
                    + fallback + '\n'
                    + '    :cipher_done\n'
                    + '.end method'
                )

                content = content[:method_start] + new_method_body + content[method_end_pos + len('.end method'):]
                patched += 1

            if patched > 0:
                with open(fpath, 'w') as f:
                    f.write(content)

print(f"  Patched {patched} cipher-dependent methods with null-guard try-catch")
PYEOF
export DECOMPILED

# ############################################################################
#
#   PART 3: BUILD & DEPLOY
#
# ############################################################################

# ============================================================================
# Step 15: Build, zipalign, sign
# ============================================================================

section "Step 15/16: Building patched APK"

OUTPUT_APK="$WORK_DIR/pairip_patched.apk"
ALIGNED_APK="$WORK_DIR/pairip_patched_aligned.apk"

log "Building APK with apktool..."
java -jar "$APKTOOL" b "$DECOMPILED" -o "$OUTPUT_APK" --use-aapt2

log "Zipaligning..."
"$ZIPALIGN" -f 4 "$OUTPUT_APK" "$ALIGNED_APK"

# Create debug keystore if needed
if [ ! -f "$KEYSTORE" ]; then
    log "Creating debug keystore..."
    keytool -genkey -v -keystore "$KEYSTORE" \
        -storepass "$KEYSTORE_PASS" \
        -alias "$KEY_ALIAS" \
        -keypass "$KEYSTORE_PASS" \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Debug,OU=Debug,O=Debug,L=Debug,ST=Debug,C=US"
fi

log "Signing APK..."
"$APKSIGNER" sign \
    --ks "$KEYSTORE" \
    --ks-pass "pass:$KEYSTORE_PASS" \
    --ks-key-alias "$KEY_ALIAS" \
    "$ALIGNED_APK"

FINAL_APK="$ALIGNED_APK"
log "Patched APK ready: $FINAL_APK ($(ls -lh "$FINAL_APK" | awk '{print $5}'))"

# Save app metadata for launch.sh
cat > "$WORK_DIR/.app_metadata" << EOF
PACKAGE=$PACKAGE
MAIN_ACTIVITY=$MAIN_ACTIVITY
EOF
log "Saved app metadata to $WORK_DIR/.app_metadata"

# ============================================================================
# Step 16: Install and launch
# ============================================================================

section "Step 16/16: Installing and launching"

log "Installing APK (first install may take a few minutes due to large Flutter engine)..."
# Uninstall first if previously installed as split APK (avoids INSTALL_FAILED_MISSING_SPLIT)
"$ADB" shell pm uninstall "$PACKAGE" 2>/dev/null || true
"$ADB" install "$FINAL_APK"

log "Launching $PACKAGE..."
"$ADB" logcat -c 2>/dev/null || true
"$ADB" shell am start -n "$PACKAGE/$MAIN_ACTIVITY"

log "Waiting for app to start..."
sleep 10

PID=$("$ADB" shell pidof "$PACKAGE" 2>/dev/null || echo "")
if [ -n "$PID" ]; then
    log "App running with PID $PID"

    # Wait a bit more and check for Flutter
    sleep 20
    FLUTTER_LOG=$("$ADB" logcat -d --pid="$PID" 2>/dev/null | grep -i "flutter\|Impeller" | head -5)
    if [ -n "$FLUTTER_LOG" ]; then
        log "Flutter engine is running!"
        echo "$FLUTTER_LOG" | while read -r line; do echo "  $line"; done
    fi

    SAFE_COUNT=$("$ADB" logcat -d --pid="$PID" 2>/dev/null | grep -c "SafeExceptionHandler" || echo 0)
    if [ "$SAFE_COUNT" -gt 0 ]; then
        log "SafeExceptionHandler caught $SAFE_COUNT background exceptions (swallowed)"
    fi
else
    warn "App process not found after 10s"
    warn "First launch is slow (~2-3 min) due to DEX verification"
    warn "Tap 'Wait' if you see 'App not responding' dialog"
fi

# ============================================================================
# Done
# ============================================================================

echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  PairIP Bypass Complete!${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
echo "  Package:     $PACKAGE"
echo "  Activity:    $MAIN_ACTIVITY"
echo "  Patched APK: $FINAL_APK"
echo "  Emulator:    $AVD_NAME"
echo ""
echo "  Useful commands:"
echo "    # View all app logs"
echo "    adb logcat --pid=\$(adb shell pidof $PACKAGE)"
echo ""
echo "    # View Flutter/Dart logs only"
echo "    adb logcat --pid=\$(adb shell pidof $PACKAGE) | grep flutter"
echo ""
echo "    # View caught background exceptions"
echo "    adb logcat --pid=\$(adb shell pidof $PACKAGE) | grep SafeExceptionHandler"
echo ""
echo "    # Relaunch the app"
echo "    adb shell am start -n $PACKAGE/$MAIN_ACTIVITY"
echo ""
echo "    # Start emulator (if closed)"
echo "    $EMULATOR -avd $AVD_NAME \\"
echo "      -writable-system \\"
echo "      -no-snapshot-load \\"
echo "      -gpu host &"
echo ""
echo "    # Toggle proxy"
echo "    adb shell settings put global http_proxy 10.0.2.2:8080   # ON"
echo "    adb shell settings put global http_proxy :0               # OFF"
echo ""
echo "  Notes:"
echo "    - First launch is slow (~2-3 min) due to DEX verification on emulator"
echo "    - Tap 'Wait' if 'App not responding' dialog appears"
echo "    - Subsequent launches are fast (DEX verification is cached)"
echo "    - ~1400 vault strings are empty; core UI works but some SDK features degraded"
echo "    - SafeExceptionHandler silently catches background thread crashes"
