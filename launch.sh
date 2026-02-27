#!/usr/bin/env bash
#
# launch.sh - One command to start capturing API traffic from PairIP-protected apps
#
# Handles everything:
#   - Starts mitmproxy if not running
#   - Starts emulator if not running
#   - Installs mitmproxy CA cert if needed
#   - Patches APK if not already patched (calls patch_pairip.sh)
#   - Installs and launches the app
#   - Auto-detects package name and activity from patch metadata
#
# Usage:
#   ./launch.sh [OPTIONS] [APK_PATH]
#
# Options:
#   --no-proxy          Disable mitmproxy (no proxy setup)
#   --proxy-port PORT   Set proxy port (default: 8080)
#   --no-emulator       Skip emulator start (assume already running)
#   --no-install        Skip APK install (assume already installed)
#   --reinstall         Force reinstall even if already installed
#   --no-launch         Skip app launch
#   --no-cert           Skip CA cert installation
#   --no-patch          Skip APK patching (use existing patched APK)
#   --cold-boot         Cold boot emulator (discard snapshot)
#   --avd NAME          AVD name (default: vogue_lab)
#   -h, --help          Show this help
#
# Examples:
#   ./launch.sh                              # full pipeline with proxy
#   ./launch.sh --no-proxy                   # launch without proxy
#   ./launch.sh --proxy-port 9090            # use custom proxy port
#   ./launch.sh --no-emulator --no-install   # just launch the app
#   ./launch.sh --reinstall ~/Downloads/V.apk  # force reinstall
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/pairip_patch"
PATCHED_APK="$WORK_DIR/pairip_patched_aligned.apk"

# Auto-detect package/activity from patch metadata (saved by patch_pairip.sh)
if [ -f "$WORK_DIR/.app_metadata" ]; then
    source "$WORK_DIR/.app_metadata"
fi
PACKAGE="${PACKAGE:-com.condenast.voguerunway}"
ACTIVITY="${MAIN_ACTIVITY:-com.rokmetro.condenast.vogue.MainActivity}"

# Defaults
OPT_PROXY=true
OPT_PROXY_PORT="8080"
OPT_EMULATOR=true
OPT_INSTALL=true
OPT_REINSTALL=false
OPT_LAUNCH=true
OPT_CERT=true
OPT_PATCH=true
OPT_AVD="vogue_lab"
OPT_COLD_BOOT=false
APK_ARG=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-proxy)
            OPT_PROXY=false
            shift
            ;;
        --proxy-port)
            OPT_PROXY_PORT="${2:?--proxy-port requires a PORT}"
            shift 2
            ;;
        --no-emulator)
            OPT_EMULATOR=false
            shift
            ;;
        --no-install)
            OPT_INSTALL=false
            shift
            ;;
        --reinstall)
            OPT_REINSTALL=true
            shift
            ;;
        --no-launch)
            OPT_LAUNCH=false
            shift
            ;;
        --no-cert)
            OPT_CERT=false
            shift
            ;;
        --no-patch)
            OPT_PATCH=false
            shift
            ;;
        --cold-boot)
            OPT_COLD_BOOT=true
            shift
            ;;
        --avd)
            OPT_AVD="${2:?--avd requires a NAME}"
            shift 2
            ;;
        -h|--help)
            sed -n '2,/^$/{ s/^# \?//; p }' "$0"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run '$0 --help' for usage" >&2
            exit 1
            ;;
        *)
            APK_ARG="$1"
            shift
            ;;
    esac
done

AVD_NAME="$OPT_AVD"
PROXY_PORT="$OPT_PROXY_PORT"

if $OPT_PROXY; then
    HTTP_PROXY="http://127.0.0.1:$PROXY_PORT"
else
    HTTP_PROXY=""
fi

ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="$ANDROID_SDK/platform-tools/adb"
EMULATOR="$ANDROID_SDK/emulator/emulator"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# ============================================================================
# 1. mitmproxy
# ============================================================================

if $OPT_PROXY; then
    if ! pgrep -f "mitmdump|mitmproxy|mitmweb" &>/dev/null; then
        command -v mitmweb &>/dev/null || command -v mitmproxy &>/dev/null || {
            die "mitmproxy not installed. Run: brew install mitmproxy"
        }

        log "Starting mitmweb on port $PROXY_PORT..."
        if command -v mitmweb &>/dev/null; then
            mitmweb --listen-port "$PROXY_PORT" --no-web-open-browser &>/tmp/mitmproxy.log &
            sleep 2
            log "mitmweb UI: http://127.0.0.1:8081"
        else
            mitmproxy --listen-port "$PROXY_PORT" &
            sleep 2
        fi
    else
        log "mitmproxy already running"
    fi

    # Make sure the CA cert exists (mitmproxy generates it on first run)
    if [ ! -f ~/.mitmproxy/mitmproxy-ca-cert.cer ]; then
        warn "Waiting for mitmproxy to generate CA cert..."
        sleep 3
    fi
else
    log "Proxy disabled (--no-proxy)"
fi

# ============================================================================
# 2. Emulator
# ============================================================================

# Flutter/Dart ignores Android's system proxy (adb shell settings put global
# http_proxy). The ONLY way to capture Flutter traffic is -http-proxy on the
# emulator, which intercepts at the QEMU network level. This means proxy
# toggling requires an emulator restart.

start_emulator() {
    # Check AVD exists
    if ! "$EMULATOR" -list-avds 2>/dev/null | grep -q "^${AVD_NAME}$"; then
        die "AVD '$AVD_NAME' not found. Run patch_pairip.sh first to create it."
    fi

    # Save snapshot and kill any existing emulator before starting a new one.
    # adb may not detect the emulator (offline/stale), so also kill by process.
    if "$ADB" shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
        log "Saving emulator snapshot (preserving login state)..."
        "$ADB" emu avd snapshot save default_boot &>/dev/null || true
        sleep 2
    fi
    "$ADB" emu kill &>/dev/null || true
    pkill -f "qemu-system.*${AVD_NAME}" 2>/dev/null || true
    sleep 3

    # Clean stale locks
    rm -f "$HOME/.android/avd/${AVD_NAME}.avd/"*.lock 2>/dev/null || true

    EMULATOR_ARGS=(-avd "$AVD_NAME" -writable-system -gpu host)
    if $OPT_COLD_BOOT; then
        EMULATOR_ARGS+=(-no-snapshot-load)
        log "Cold boot (--cold-boot)"
    fi
    if $OPT_PROXY; then
        EMULATOR_ARGS+=(-http-proxy "http://127.0.0.1:$PROXY_PORT")
        log "Starting emulator with proxy → 127.0.0.1:$PROXY_PORT"
    else
        log "Starting emulator without proxy"
    fi
    "$EMULATOR" "${EMULATOR_ARGS[@]}" &>/tmp/emulator_pairip.log &

    log "Waiting for boot..."
    TIMEOUT=180
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
            log "Booted in ${ELAPSED}s"
            break
        fi
    done

    [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null)" = "1" ] || die "Emulator boot timed out"
    sleep 3
}

if ! $OPT_EMULATOR; then
    log "Skipping emulator start (--no-emulator)"
elif ! "$ADB" devices 2>/dev/null | grep -q "emulator.*device$"; then
    start_emulator
else
    # Emulator is running — check if proxy state matches
    # Read the emulator's kernel command line to see if -http-proxy was set
    EMU_PROXY=$("$ADB" shell getprop persist.sys.global_proxy 2>/dev/null || echo "")
    NEED_RESTART=false

    if $OPT_PROXY && [ -z "$EMU_PROXY" ]; then
        warn "Emulator running without -http-proxy but proxy requested"
        NEED_RESTART=true
    elif ! $OPT_PROXY && [ -n "$EMU_PROXY" ] && [ "$EMU_PROXY" != ":0" ]; then
        warn "Emulator running with -http-proxy but --no-proxy requested"
        NEED_RESTART=true
    fi

    if $NEED_RESTART; then
        log "Restarting emulator to toggle proxy..."
        start_emulator
    else
        log "Emulator already running (proxy state matches)"
    fi
fi

# ============================================================================
# 3. mitmproxy CA cert (system-level)
# ============================================================================

if $OPT_PROXY && $OPT_CERT && [ -f ~/.mitmproxy/mitmproxy-ca-cert.cer ]; then
    CERT_HASH=$(openssl x509 -inform PEM -subject_hash_old \
        -in ~/.mitmproxy/mitmproxy-ca-cert.cer 2>/dev/null | head -1)

    if ! "$ADB" shell ls "/system/etc/security/cacerts/${CERT_HASH}.0" &>/dev/null; then
        log "Installing mitmproxy CA cert as system certificate..."

        openssl x509 -inform PEM \
            -in ~/.mitmproxy/mitmproxy-ca-cert.cer \
            -out "/tmp/${CERT_HASH}.0"

        "$ADB" root &>/dev/null && sleep 2
        "$ADB" remount &>/dev/null && sleep 2

        # Check if reboot is needed (first time enabling overlayfs)
        REMOUNT_OUT=$("$ADB" remount 2>&1)
        if echo "$REMOUNT_OUT" | grep -qi "reboot"; then
            log "Rebooting to enable writable system..."
            "$ADB" reboot
            sleep 5
            while [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
                sleep 5
            done
            sleep 3
            "$ADB" root &>/dev/null && sleep 2
            "$ADB" remount &>/dev/null && sleep 2
        fi

        "$ADB" push "/tmp/${CERT_HASH}.0" "/system/etc/security/cacerts/${CERT_HASH}.0" &>/dev/null
        "$ADB" shell chmod 644 "/system/etc/security/cacerts/${CERT_HASH}.0"
        log "CA cert installed: ${CERT_HASH}.0"
    else
        log "mitmproxy CA cert already installed"
    fi
fi

# ============================================================================
# 4. Patch APK if needed
# ============================================================================

if ! $OPT_PATCH; then
    log "Skipping APK patching (--no-patch)"
elif [ ! -f "$PATCHED_APK" ]; then
    warn "Patched APK not found. Running patch_pairip.sh..."

    APK_INPUT="$APK_ARG"
    if [ -z "$APK_INPUT" ]; then
        # Try to find APK in common locations
        for candidate in \
            "$SCRIPT_DIR"/*.apk \
            ~/Downloads/Vogue_*/*.apk \
            ~/Downloads/com.condenast.voguerunway*.apk; do
            if [ -f "$candidate" ] 2>/dev/null; then
                APK_INPUT="$candidate"
                break
            fi
        done
    fi

    [ -n "$APK_INPUT" ] && [ -f "$APK_INPUT" ] || die "APK not found. Usage: $0 <path-to-apk>"

    log "Patching: $APK_INPUT"
    "$SCRIPT_DIR/patch_pairip.sh" "$APK_INPUT"
fi

# ============================================================================
# 5. Install if needed
# ============================================================================

if ! $OPT_INSTALL; then
    log "Skipping install (--no-install)"
else
    APK_MOD=$(stat -f %m "$PATCHED_APK" 2>/dev/null || stat -c %Y "$PATCHED_APK" 2>/dev/null || echo 0)
    MARKER="$WORK_DIR/.installed_ts"
    LAST_INSTALL=$(cat "$MARKER" 2>/dev/null || echo 0)
    INSTALLED=$("$ADB" shell pm list packages 2>/dev/null | grep -c "$PACKAGE" || echo 0)

    if $OPT_REINSTALL; then
        log "Force reinstalling (app data will be cleared)..."
        "$ADB" shell pm uninstall "$PACKAGE" 2>/dev/null || true
        "$ADB" install "$PATCHED_APK"
    elif [ "$INSTALLED" -eq 0 ] || [ "$APK_MOD" -gt "$LAST_INSTALL" ]; then
        log "Installing patched APK (preserving app data)..."
        "$ADB" install -r "$PATCHED_APK" 2>/dev/null || {
            warn "Replace install failed, doing clean install..."
            "$ADB" shell pm uninstall "$PACKAGE" 2>/dev/null || true
            "$ADB" install "$PATCHED_APK"
        }
    else
        log "App already installed (use --reinstall to force)"
    fi
    echo "$APK_MOD" > "$WORK_DIR/.installed_ts" 2>/dev/null || true
fi

# ============================================================================
# 6. Set system proxy (supplement for non-Flutter traffic like WebViews)
# ============================================================================
# The -http-proxy flag handles Flutter/Dart traffic at the QEMU level.
# This additionally sets Android's system proxy for WebView/Chrome/SDK traffic.

if $OPT_PROXY; then
    log "Setting system proxy → 10.0.2.2:$PROXY_PORT"
    "$ADB" shell settings put global http_proxy "10.0.2.2:$PROXY_PORT"
else
    log "Clearing system proxy"
    "$ADB" shell settings delete global http_proxy 2>/dev/null || true
    "$ADB" shell settings put global http_proxy :0 2>/dev/null || true
fi

# ============================================================================
# 7. Launch
# ============================================================================

if ! $OPT_LAUNCH; then
    log "Skipping app launch (--no-launch)"
else
    log "Launching $PACKAGE..."
    "$ADB" shell am force-stop "$PACKAGE" 2>/dev/null || true
    "$ADB" shell am start -n "$PACKAGE/$ACTIVITY"

    sleep 5
    PID=$("$ADB" shell pidof "$PACKAGE" 2>/dev/null || echo "")

    echo ""
    if [ -n "$PID" ]; then
        echo -e "${GREEN}${BOLD}App is running (PID $PID)${NC}"
    else
        echo -e "${YELLOW}${BOLD}App is starting (first launch is slow ~2min, tap 'Wait' on ANR dialog)${NC}"
    fi
fi

echo ""
if $OPT_PROXY; then
    echo -e "  ${CYAN}Proxy:${NC}    $HTTP_PROXY"
    echo -e "  ${CYAN}mitmweb:${NC}  http://127.0.0.1:8081"
fi
echo -e "  ${CYAN}Logs:${NC}     adb logcat --pid=\$(adb shell pidof $PACKAGE) | grep flutter"
echo -e "  ${CYAN}Relaunch:${NC} adb shell am start -n $PACKAGE/$ACTIVITY"
echo ""
