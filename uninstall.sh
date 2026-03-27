#!/system/bin/sh
# ╔══════════════════════════════════════════════════════╗
# ║  UAPE v3 — Uninstaller                              ║
# ║  Universal Android Performance Engine               ║
# ║  Dev: mrk/gellado  |  tg: @yubk / @mrk             ║
# ╚══════════════════════════════════════════════════════╝

BASE_DIR="/data/adb"
SERVICE_DST="$BASE_DIR/service.sh"
CONF="$BASE_DIR/optimizer.conf"
LOG="$BASE_DIR/optimizer.log"
PID_FILE="$BASE_DIR/optimizer.pid"
PROF_DIR="$BASE_DIR/game_profiles"
AI_DIR="$BASE_DIR/ai_state"
LAUNCHER_SD="$BASE_DIR/service.d/99-uape.sh"
LAUNCHER_INITD="/system/etc/init.d/99uape"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[0m'

say()  { printf "${B}[UAPE]${W} %s\n" "$*"; }
ok()   { printf "${G}[  OK ]${W} %s\n" "$*"; }
warn() { printf "${Y}[WARN ]${W} %s\n" "$*"; }
die()  { printf "${R}[FAIL ]${W} %s\n" "$*"; exit 1; }

echo ""
printf "${C}╔══════════════════════════════════════╗${W}\n"
printf "${C}║  UAPE v3  Uninstaller                ║${W}\n"
printf "${C}╚══════════════════════════════════════╝${W}\n"
echo ""

[ "$(id -u)" -ne 0 ] && die "Root required."

printf "${Y}Remove UAPE engine and all files? [y/N]: ${W}"
read -r _ans
case "$_ans" in [Yy]*) ;; *) say "Aborted."; exit 0;; esac

printf "${B}Keep per-game profiles? [Y/n]: ${W}"
read -r _kp; case "$_kp" in [Nn]*) KEEP_PROF=0;; *) KEEP_PROF=1;; esac

printf "${B}Keep AI state / tuned gains? [Y/n]: ${W}"
read -r _ka; case "$_ka" in [Nn]*) KEEP_AI=0;; *) KEEP_AI=1;; esac

printf "${B}Keep optimizer.conf? [Y/n]: ${W}"
read -r _kc; case "$_kc" in [Nn]*) KEEP_CONF=0;; *) KEEP_CONF=1;; esac

echo ""

# ── Stop engine ──
say "Stopping engine..."
if [ -f "$PID_FILE" ]; then
    _pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$_pid" ] && [ -d "/proc/$_pid" ]; then
        kill "$_pid" 2>/dev/null; sleep 2
        [ -d "/proc/$_pid" ] && kill -9 "$_pid" 2>/dev/null
        ok "Stopped PID=$_pid"
    else
        warn "PID file found but process already stopped"
    fi
    rm -f "$PID_FILE"
else
    warn "Engine was not running"
fi

# Kill any orphaned service.sh processes
for _p in $(ps 2>/dev/null | grep "[s]ervice.sh" | awk '{print $1}'); do
    kill "$_p" 2>/dev/null && ok "Killed orphan PID=$_p"
done

# ── Restore CPU to stock ──
say "Restoring CPU..."
for _pol in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol" ] || continue
    _hw=$(cat "$_pol/cpuinfo_max_freq" 2>/dev/null)
    _mn=$(cat "$_pol/cpuinfo_min_freq" 2>/dev/null)
    [ -n "$_hw" ] && echo "$_hw" > "$_pol/scaling_max_freq" 2>/dev/null
    [ -n "$_mn" ] && echo "$_mn" > "$_pol/scaling_min_freq" 2>/dev/null
    # Restore governor
    _avail=$(cat "$_pol/scaling_available_governors" 2>/dev/null)
    if echo "$_avail" | grep -q schedutil; then
        echo schedutil > "$_pol/scaling_governor" 2>/dev/null
    elif echo "$_avail" | grep -q interactive; then
        echo interactive > "$_pol/scaling_governor" 2>/dev/null
    fi
done
ok "CPU restored to stock"

# ── Restore GPU to stock ──
say "Restoring GPU..."
[ -f /sys/kernel/ged/hal/boost_gpu_enable ] && \
    echo 0 > /sys/kernel/ged/hal/boost_gpu_enable 2>/dev/null
if [ -d /sys/class/kgsl/kgsl-3d0 ]; then
    _hw=$(cat /sys/class/kgsl/kgsl-3d0/devfreq/max_freq 2>/dev/null)
    [ -n "$_hw" ] && echo "$_hw" > /sys/class/kgsl/kgsl-3d0/devfreq/max_freq 2>/dev/null
    echo 0 > /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 2>/dev/null
fi
for _m in /sys/class/misc/mali0 /sys/devices/platform/*.mali; do
    [ -d "$_m" ] || continue
    _hw=$(cat "$_m/max_clock" 2>/dev/null)
    [ -n "$_hw" ] && echo "$_hw" > "$_m/max_clock" 2>/dev/null
    echo 0 > "$_m/min_clock" 2>/dev/null
done
for _d in /sys/class/devfreq/*; do
    [ -d "$_d" ] || continue
    _n=$(cat "$_d/name" 2>/dev/null || basename "$_d")
    case "$_n" in *gpu*|*mali*|*adreno*|*sgpu*|*xclipse*)
        _hw=$(cat "$_d/max_freq" 2>/dev/null)
        [ -n "$_hw" ] && echo "$_hw" > "$_d/max_freq" 2>/dev/null
        echo 0 > "$_d/min_freq" 2>/dev/null;; esac
done
ok "GPU restored to stock"

# ── Remove files ──
say "Removing files..."
[ -f "$SERVICE_DST"    ] && rm -f "$SERVICE_DST"    && ok "Removed: $SERVICE_DST"
[ -f "$LAUNCHER_SD"    ] && rm -f "$LAUNCHER_SD"    && ok "Removed: $LAUNCHER_SD"
[ -f "$LAUNCHER_INITD" ] && rm -f "$LAUNCHER_INITD" && ok "Removed: $LAUNCHER_INITD"

[ "$KEEP_CONF" = "0" ] && rm -f   "$CONF"    && ok "Removed: $CONF"    || warn "Kept: $CONF"
[ "$KEEP_PROF" = "0" ] && rm -rf  "$PROF_DIR" && ok "Removed: $PROF_DIR" || warn "Kept: $PROF_DIR"
[ "$KEEP_AI"   = "0" ] && rm -rf  "$AI_DIR"   && ok "Removed: $AI_DIR"   || warn "Kept: $AI_DIR"
warn "Last log kept: $LOG"

echo ""
printf "${G}╔══════════════════════════════════════╗${W}\n"
printf "${G}║  Uninstall complete.                 ║${W}\n"
printf "${G}╚══════════════════════════════════════╝${W}\n"
echo ""
