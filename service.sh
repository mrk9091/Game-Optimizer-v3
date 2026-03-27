#!/system/bin/sh
# MIT License
# 
# Copyright (c) Mar-27-2026 mrk/gellado
VERSION="3.0"
ENGINE="UAPE"
BASE_DIR="/data/adb"
LOG="$BASE_DIR/optimizer.log"
PID_FILE="$BASE_DIR/optimizer.pid"
CONF="$BASE_DIR/optimizer.conf"
PROF_DIR="$BASE_DIR/game_profiles"
AI_DIR="$BASE_DIR/ai_state"

# ── Single-instance guard ──
[ -f "$PID_FILE" ] && [ -d "/proc/$(cat "$PID_FILE" 2>/dev/null)" ] && exit 0
echo $$ > "$PID_FILE"

# ── Root check ──
[ "$(id -u)" -ne 0 ] && {
    echo "[$ENGINE] Root required" >&2
    rm -f "$PID_FILE"; exit 1
}

echo -1000 > /proc/self/oom_score_adj 2>/dev/null
mkdir -p "$BASE_DIR" "$PROF_DIR" "$AI_DIR"
touch "$LOG"
[ -f "$CONF" ] && . "$CONF"

# ═══════════════════════════════════════
# TUNABLES  (override in optimizer.conf)
# ═══════════════════════════════════════

# FPS  (0 = auto-detect from display hardware)
: "${TARGET_FPS:=0}"
: "${FPS_DROP_REACT:=4}"
: "${FPS_CRIT_DROP:=10}"
: "${FPS_STUTTER_THRESH:=10}"

# Thermal (°C)
: "${THERMAL_SAFE:=52}"
: "${THERMAL_WARM:=58}"
: "${THERMAL_HOT:=63}"
: "${THERMAL_CRIT:=67}"
: "${THERMAL_EMERG:=72}"
: "${THERMAL_HYST:=3}"

# Predictive thermal — how many seconds ahead to project
: "${THERM_LOOKAHEAD:=6}"

# Frequency floor bounds  (% of hardware max — ceiling NEVER raised)
: "${FLOOR_MIN_PCT:=18}"
: "${FLOOR_MAX_PCT:=70}"
: "${GPU_FLOOR_MIN_PCT:=15}"
: "${GPU_FLOOR_MAX_PCT:=62}"

# Governor responsiveness
: "${GOV_UP_US:=400}"
: "${GOV_DOWN_US:=3500}"

# Battery thresholds (%)
: "${BATT_LOW:=15}"
: "${BATT_MED:=30}"

# Timing
: "${IDLE_SLEEP:=12}"
: "${SCREEN_OFF_SLEEP:=30}"

# Logging: 0=silent 1=normal 2=verbose
: "${LOG_LEVEL:=1}"
: "${LOG_LOGCAT:=0}"

# Light floor for non-game foreground apps
: "${NON_GAME_FLOOR:=1}"

# EMA alpha (0–9 tenths, higher = faster response, lower = smoother)
# 7 = α=0.7 responsive,  4 = α=0.4 smooth
: "${EMA_ALPHA:=6}"

# Self-tuning PID: allow gains to adapt over sessions (0/1)
: "${AI_SELF_TUNE:=1}"

# Game package list  (prefix-matched)
: "${GAME_LIST:=com.miHoYo com.HoYoverse com.kurogame com.tencent.ig com.pubg com.activision.callofduty com.garena com.dts.freefireth com.mojang com.mobile.legends com.riotgames com.supercell com.innersloth com.ea.gp com.netease com.epicgames com.blizzard com.gameloft com.kabam com.squareenix com.bandainamco com.sega com.nianticlabs com.nexon com.netmarble com.lilithgames com.yostar com.robtopx com.nekki com.fingersoft com.igg com.plarium com.scopely com.ketchapp com.miniclip com.gamevil com.snail com.gtarcade com.perfectworld com.farlightgames com.habby com.vng com.levelinfinite com.proximabeta com.dragonest com.tencent.tmgp com.tencent.lolm com.pearlabyss com.krafton com.xd com.neople}"

# ═══════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════
log() {
    _lvl=${3:-1}
    [ "$_lvl" -gt "$LOG_LEVEL" ] && return
    _line="$(date '+%H:%M:%S') [$1] $2"
    echo "$_line" >> "$LOG"
    [ "$LOG_LOGCAT" = "1" ] && log -t "$ENGINE/$1" "$2" 2>/dev/null
}
log_trim() {
    _lc=$(wc -l < "$LOG" 2>/dev/null)
    [ "${_lc:-0}" -gt 600 ] && tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# ── Wait for boot ──
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 7
log "INIT" "$ENGINE v$VERSION  PID=$$"

# ═══════════════════════════════════════
# SAFE WRITE
# ═══════════════════════════════════════
write() {
    [ -f "$1" ] && [ -w "$1" ] || return 1
    [ "$(cat "$1" 2>/dev/null)" = "$2" ] && return 0
    echo "$2" > "$1" 2>/dev/null
}

# ═══════════════════════════════════════
# SIGNAL HANDLING
# ═══════════════════════════════════════
_exit_handler() {
    log "EXIT" "Signal — restoring hardware defaults"
    cpu_restore_all; gpu_restore; set_gov
    rm -f "$PID_FILE"; exit 0
}
_stat_handler() {
    log "STAT" "APP=$CUR_APP FPS=$FPS EMA=$EMA_FPS T=$TEMP($THERM_LVL) FLOOR=C${FLOOR_CPU}G${FLOOR_GPU} WLOAD=$WLOAD SCORE=$SMOOTH_SCORE"
}
trap '_exit_handler'  TERM INT
trap '_stat_handler'  USR1

# ═══════════════════════════════════════
# ██ HARDWARE DISCOVERY ██
# ═══════════════════════════════════════
POLICY_LIST=$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null)
MAXF=0; CORES=4; TIER="MID"
BIG=""; LITTLE=""; PRIME=""

# Tier defaults
BASE_FLOOR_CPU=30; BASE_FLOOR_GPU=24
KP=18; KI=4; KD=11; I_CLAMP=45; RATE_LIMIT=8

detect_tier() {
    MAXF=0
    for _p in $POLICY_LIST; do
        _f=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null)
        [ -n "$_f" ] && [ "$_f" -gt "$MAXF" ] && MAXF=$_f
    done
    CORES=$(nproc 2>/dev/null); : "${CORES:=4}"
    _ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | tr -dc '0-9')
    RAM_GB=$(( ${_ram_kb:-4000000} / 1048576 ))

    if   [ "$MAXF" -ge 3000000 ] && [ "$RAM_GB" -ge 8 ] && [ "$CORES" -ge 8 ]; then
        TIER="FLAGSHIP"
        BASE_FLOOR_CPU=38; BASE_FLOOR_GPU=30
        KP=12; KI=2; KD=8;  I_CLAMP=40; RATE_LIMIT=5
    elif [ "$MAXF" -ge 2800000 ] && [ "$RAM_GB" -ge 6 ]; then
        TIER="HIGH"
        BASE_FLOOR_CPU=35; BASE_FLOOR_GPU=27
        KP=14; KI=3; KD=9;  I_CLAMP=42; RATE_LIMIT=6
    elif [ "$MAXF" -ge 2200000 ] && [ "$RAM_GB" -ge 4 ]; then
        TIER="MID"
        BASE_FLOOR_CPU=30; BASE_FLOOR_GPU=24
        KP=18; KI=4; KD=11; I_CLAMP=45; RATE_LIMIT=8
    elif [ "$MAXF" -ge 1800000 ]; then
        TIER="LOW_MID"
        BASE_FLOOR_CPU=28; BASE_FLOOR_GPU=22
        KP=20; KI=4; KD=12; I_CLAMP=50; RATE_LIMIT=9
    else
        TIER="LOW"
        BASE_FLOOR_CPU=26; BASE_FLOOR_GPU=20
        KP=22; KI=5; KD=13; I_CLAMP=55; RATE_LIMIT=10
    fi

    log "TIER" "$TIER  MAX=${MAXF}KHz  CORES=$CORES  RAM=${RAM_GB}GB"
}

cluster_init() {
    BIG=""; LITTLE=""; PRIME=""
    for _p in $POLICY_LIST; do
        _max=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null); [ -z "$_max" ] && continue
        if   [ "$_max" -ge $(( MAXF * 95 / 100 )) ] && [ "$CORES" -ge 6 ]; then PRIME="$PRIME $_p"
        elif [ "$_max" -ge $(( MAXF * 68 / 100 )) ];                         then BIG="$BIG $_p"
        else                                                                       LITTLE="$LITTLE $_p"
        fi
    done
    _cnt=0
    [ -n "$PRIME" ]  && _cnt=$(( _cnt+1 ))
    [ -n "$BIG" ]    && _cnt=$(( _cnt+1 ))
    [ -n "$LITTLE" ] && _cnt=$(( _cnt+1 ))
    [ "$_cnt" -le 1 ] && { BIG="$PRIME $BIG $LITTLE"; PRIME=""; LITTLE=""; }
    log "CLUSTER" "PRIME=[$PRIME] BIG=[$BIG] LITTLE=[$LITTLE]" 2
}

# ═══════════════════════════════════════
# GOVERNOR  — fast ramp-up, slow ramp-down
# ═══════════════════════════════════════
set_gov() {
    for _p in $POLICY_LIST; do
        _g=$(cat "$_p/scaling_available_governors" 2>/dev/null)
        if echo "$_g" | grep -q schedutil; then
            write "$_p/scaling_governor" schedutil
            [ -d "$_p/schedutil" ] && {
                write "$_p/schedutil/up_rate_limit_us"   "$GOV_UP_US"
                write "$_p/schedutil/down_rate_limit_us" "$GOV_DOWN_US"
                write "$_p/schedutil/hispeed_load"       90 2>/dev/null
            }
        elif echo "$_g" | grep -q walt;        then write "$_p/scaling_governor" walt
        elif echo "$_g" | grep -q interactive; then write "$_p/scaling_governor" interactive
        fi
    done
}

# ═══════════════════════════════════════
# CPU FLOOR CONTROL
# ► max_freq NEVER set above hardware stock
# ► Only min_freq (floor) moves
# ═══════════════════════════════════════
cpu_set_floor() {
    _fpct=$1
    for _p in $PRIME $BIG; do
        _hw=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null); [ -z "$_hw" ] && continue
        _mn=$(cat "$_p/cpuinfo_min_freq" 2>/dev/null)
        write "$_p/scaling_max_freq" "$_hw"          # ceiling = stock always
        _fl=$(( _hw * _fpct / 100 ))
        [ "$_fl" -lt "${_mn:-0}" ] && _fl=${_mn:-0}
        [ "$_fl" -gt "$_hw"      ] && _fl=$_hw
        write "$_p/scaling_min_freq" "$_fl"
    done
    # LITTLE cluster: 78% of big floor (handles background work)
    _little_pct=$(( _fpct * 78 / 100 ))
    for _p in $LITTLE; do
        _hw=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null); [ -z "$_hw" ] && continue
        _mn=$(cat "$_p/cpuinfo_min_freq" 2>/dev/null)
        write "$_p/scaling_max_freq" "$_hw"
        _fl=$(( _hw * _little_pct / 100 ))
        [ "$_fl" -lt "${_mn:-0}" ] && _fl=${_mn:-0}
        [ "$_fl" -gt "$_hw"      ] && _fl=$_hw
        write "$_p/scaling_min_freq" "$_fl"
    done
}

# Thermal ceiling throttle — ONLY downward from stock, never above
cpu_throttle_ceil() {
    _cpct=$1
    for _p in $POLICY_LIST; do
        _hw=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null); [ -z "$_hw" ] && continue
        _mn=$(cat "$_p/cpuinfo_min_freq" 2>/dev/null)
        _ceil=$(( _hw * _cpct / 100 ))
        [ "$_ceil" -lt "${_mn:-0}" ] && _ceil=${_mn:-0}
        write "$_p/scaling_max_freq" "$_ceil"
        # floor must not exceed new ceiling
        _cur_fl=$(cat "$_p/scaling_min_freq" 2>/dev/null)
        [ -n "$_cur_fl" ] && [ "$_cur_fl" -gt "$_ceil" ] && write "$_p/scaling_min_freq" "$_ceil"
    done
}

cpu_restore_all() {
    for _p in $POLICY_LIST; do
        _hw=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null); [ -z "$_hw" ] && continue
        _mn=$(cat "$_p/cpuinfo_min_freq" 2>/dev/null)
        write "$_p/scaling_max_freq" "$_hw"
        write "$_p/scaling_min_freq" "${_mn:-0}"
    done
}

# ═══════════════════════════════════════
# GPU  DETECTION & FLOOR CONTROL
# ═══════════════════════════════════════
GPU_TYPE="NONE"; GPU_PATH=""; GPU_LOAD_NODE=""; GPU_HW_MAX=0

detect_gpu() {
    # GED (MediaTek newer)
    if [ -d /sys/kernel/ged/hal ]; then
        GPU_TYPE="GED"; GPU_PATH="/sys/kernel/ged/hal"
        [ -f "$GPU_PATH/gpu_utilization" ] && GPU_LOAD_NODE="$GPU_PATH/gpu_utilization"
        log "GPU" "MediaTek GED"; return
    fi
    # MTK legacy
    if [ -d /proc/gpufreq ]; then
        GPU_TYPE="MTK"; GPU_PATH="/proc/gpufreq"
        log "GPU" "MediaTek legacy"; return
    fi
    # Qualcomm Adreno kgsl
    if [ -d /sys/class/kgsl/kgsl-3d0 ]; then
        GPU_TYPE="ADRENO"; GPU_PATH="/sys/class/kgsl/kgsl-3d0"
        GPU_HW_MAX=$(cat "$GPU_PATH/devfreq/max_freq" 2>/dev/null)
        [ -f "$GPU_PATH/gpu_busy_percentage" ] && GPU_LOAD_NODE="$GPU_PATH/gpu_busy_percentage"
        [ -f "$GPU_PATH/gpubusy" ]             && GPU_LOAD_NODE="$GPU_PATH/gpubusy"
        log "GPU" "Adreno kgsl  HW_MAX=$GPU_HW_MAX"; return
    fi
    # Mali direct sysfs (Exynos)
    for _m in /sys/class/misc/mali0 /sys/devices/platform/*.mali /sys/devices/platform/mali-*.0; do
        [ -d "$_m" ] || continue
        GPU_TYPE="MALI"; GPU_PATH="$_m"
        [ -f "$_m/utilization" ]     && GPU_LOAD_NODE="$_m/utilization"
        [ -f "$_m/gpu_utilization" ] && GPU_LOAD_NODE="$_m/gpu_utilization"
        GPU_HW_MAX=$(cat "$_m/max_clock" 2>/dev/null)
        log "GPU" "Mali: $_m"; return
    done
    # Generic devfreq scan
    for _d in /sys/class/devfreq/*; do
        [ -d "$_d" ] || continue
        _n=$(cat "$_d/device/of_node/compatible" 2>/dev/null \
             || cat "$_d/name" 2>/dev/null \
             || basename "$_d")
        case "$_n" in
            *mali*|*gpu*|*adreno*|*kgsl*|*sgpu*|*xclipse*|*powervr*|*rgx*)
                GPU_TYPE="DEVFREQ"; GPU_PATH="$_d"
                [ -f "$_d/load" ]        && GPU_LOAD_NODE="$_d/load"
                [ -f "$_d/utilization" ] && GPU_LOAD_NODE="$_d/utilization"
                GPU_HW_MAX=$(cat "$_d/max_freq" 2>/dev/null)
                log "GPU" "devfreq:$_n  HW_MAX=$GPU_HW_MAX"; return;;
        esac
    done
    GPU_TYPE="NONE"; log "GPU" "No supported GPU sysfs found"
}

gpu_set_floor() {
    _pct=$1; [ "$_pct" -gt 100 ] && _pct=100; [ "$_pct" -lt 0 ] && _pct=0
    case "$GPU_TYPE" in
        GED)
            # Stability only — no boost enable, let driver govern freely
            write "$GPU_PATH/boost_gpu_enable" 0;;
        MTK)
            write "$GPU_PATH/gpufreq_opp_freq" -1;;
        MALI)
            [ -z "$GPU_HW_MAX" ] || [ "$GPU_HW_MAX" -eq 0 ] && return
            _fl=$(( GPU_HW_MAX * _pct / 100 ))
            write "$GPU_PATH/max_clock" "$GPU_HW_MAX"  # ceiling = stock
            write "$GPU_PATH/min_clock" "$_fl" 2>/dev/null;;
        DEVFREQ)
            [ -z "$GPU_HW_MAX" ] || [ "$GPU_HW_MAX" -eq 0 ] && return
            _fl=$(( GPU_HW_MAX * _pct / 100 ))
            write "$GPU_PATH/max_freq" "$GPU_HW_MAX"   # ceiling = stock
            write "$GPU_PATH/min_freq" "$_fl";;
        ADRENO)
            [ -z "$GPU_HW_MAX" ] || [ "$GPU_HW_MAX" -eq 0 ] && return
            _fl=$(( GPU_HW_MAX * _pct / 100 ))
            write "$GPU_PATH/devfreq/max_freq" "$GPU_HW_MAX"  # ceiling = stock
            write "$GPU_PATH/devfreq/min_freq" "$_fl";;
    esac
}

gpu_throttle_ceil() {
    _pct=$1
    [ -z "$GPU_HW_MAX" ] || [ "$GPU_HW_MAX" -eq 0 ] && return
    _ceil=$(( GPU_HW_MAX * _pct / 100 ))
    case "$GPU_TYPE" in
        DEVFREQ) write "$GPU_PATH/max_freq" "$_ceil";;
        ADRENO)  write "$GPU_PATH/devfreq/max_freq" "$_ceil";;
        MALI)    write "$GPU_PATH/max_clock" "$_ceil" 2>/dev/null;;
        GED)     : ;; # GED thermal handled by driver
    esac
}

gpu_restore() {
    case "$GPU_TYPE" in
        GED)     write "$GPU_PATH/boost_gpu_enable" 0;;
        MTK)     write "$GPU_PATH/gpufreq_opp_freq" -1;;
        MALI)    [ -n "$GPU_HW_MAX" ] && write "$GPU_PATH/max_clock" "$GPU_HW_MAX" 2>/dev/null
                 write "$GPU_PATH/min_clock" 0 2>/dev/null;;
        DEVFREQ) [ -n "$GPU_HW_MAX" ] && write "$GPU_PATH/max_freq" "$GPU_HW_MAX"
                 write "$GPU_PATH/min_freq" 0;;
        ADRENO)  [ -n "$GPU_HW_MAX" ] && write "$GPU_PATH/devfreq/max_freq" "$GPU_HW_MAX"
                 write "$GPU_PATH/devfreq/min_freq" 0;;
    esac
}

gpu_load() {
    case "$GPU_TYPE" in
        GED)
            _u=$(cat "$GPU_PATH/gpu_utilization" 2>/dev/null | tr -dc '0-9' | head -c3)
            [ -n "$_u" ] && echo "$_u" || echo 50;;
        DEVFREQ|ADRENO|MALI)
            if [ -n "$GPU_LOAD_NODE" ] && [ -f "$GPU_LOAD_NODE" ]; then
                _v=$(cat "$GPU_LOAD_NODE" 2>/dev/null | tr -dc '0-9' | head -c3)
                [ -n "$_v" ] && [ "$_v" -le 100 ] && echo "$_v" && return
            fi
            if [ "$GPU_TYPE" = "ADRENO" ] && [ -f "$GPU_PATH/gpubusy" ]; then
                read _busy _total 2>/dev/null < "$GPU_PATH/gpubusy"
                [ -n "$_total" ] && [ "$_total" -gt 0 ] && echo $(( 100*_busy/_total )) && return
            fi
            echo 50;;
        *) echo 50;;
    esac
}

# ═══════════════════════════════════════
# DISPLAY REFRESH RATE AUTO-DETECT
# ═══════════════════════════════════════
detect_display_fps() {
    # Method 1: fb0/modes — format is like "U:1080x2460p-60" or "1080x1920-60"
    # We extract the number AFTER the last hyphen/dash, NOT the last number overall
    # (the last number overall would be the height e.g. 2460)
    for _node in \
        /sys/class/graphics/fb0/modes \
        /sys/class/drm/card0-DSI-1/modes \
        /sys/class/drm/card0/modes \
        /sys/devices/platform/*/drm/card*/*/modes; do
        [ -f "$_node" ] || continue
        # Extract number after last '-' or 'p-' — this is the refresh rate
        _fps=$(grep -oE '\-[0-9]+$|p\-[0-9]+$' "$_node" | grep -oE '[0-9]+$' | head -1)
        # Validate: real refresh rates are 30–165Hz, not 2160/2460/1080 (resolutions)
        if [ -n "$_fps" ] && [ "$_fps" -ge 30 ] && [ "$_fps" -le 165 ]; then
            echo "$_fps"; return
        fi
    done

    # Method 2: dumpsys display — look for refreshRate field
    _fps=$(dumpsys display 2>/dev/null | grep -i "refreshRate" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
    if [ -n "$_fps" ] && [ "$_fps" -ge 30 ] && [ "$_fps" -le 165 ]; then
        echo "$_fps"; return
    fi

    # Method 3: dumpsys display — look for mode line like "60 Hz" or "90 Hz"
    _fps=$(dumpsys display 2>/dev/null | grep -oE '[0-9]+\.?[0-9]* Hz' | grep -oE '^[0-9]+' | head -1)
    if [ -n "$_fps" ] && [ "$_fps" -ge 30 ] && [ "$_fps" -le 165 ]; then
        echo "$_fps"; return
    fi

    # Method 4: wm size fallback — just default to 60
    log "INIT" "Could not detect display Hz — defaulting to 60. Set TARGET_FPS in optimizer.conf to override."
    echo 60
}

# ═══════════════════════════════════════
# ██ AI SYSTEM 1: EMA FPS SMOOTHER ██
# Exponential Moving Average removes noise
# from frame counter deltas. Alpha is tunable.
# EMA_FPS is the clean signal the PID uses.
# ═══════════════════════════════════════
EMA_FPS=-1       # the smoothed FPS signal
EMA_INIT=0       # has EMA been seeded?

ema_update() {
    _raw=$1
    [ "$_raw" -lt 0 ] && return
    if [ "$EMA_INIT" -eq 0 ]; then
        EMA_FPS=$_raw; EMA_INIT=1; return
    fi
    # EMA = alpha*raw + (1-alpha)*prev   (scaled *10 to avoid floats)
    # EMA_ALPHA=6 → alpha=0.6
    EMA_FPS=$(( (EMA_ALPHA * _raw + (10 - EMA_ALPHA) * EMA_FPS) / 10 ))
}

# ═══════════════════════════════════════
# ██ AI SYSTEM 2: ANOMALY FILTER ██
# Detects FPS readings that are statistical
# outliers (loading screens, transitions).
# Returns 1 if reading should be ignored.
# ═══════════════════════════════════════
ANML_HI_CNT=0   # consecutive high-FPS anomaly count
ANML_LO_CNT=0

anomaly_check() {
    _fps=$1
    [ "$EMA_INIT" -eq 0 ] && echo 0 && return

    # A reading is anomalous if it deviates > 40% from EMA
    _dev=$(( _fps - EMA_FPS ))
    [ "$_dev" -lt 0 ] && _dev=$(( -_dev ))
    _thresh=$(( EMA_FPS * 40 / 100 ))
    [ "$_thresh" -lt 10 ] && _thresh=10

    if [ "$_dev" -gt "$_thresh" ]; then
        # Need 2 consecutive anomalies before acting — prevents false positives
        if [ "$_fps" -gt "$EMA_FPS" ]; then
            ANML_HI_CNT=$(( ANML_HI_CNT + 1 ))
            ANML_LO_CNT=0
            [ "$ANML_HI_CNT" -lt 2 ] && echo 1 && return
        else
            ANML_LO_CNT=$(( ANML_LO_CNT + 1 ))
            ANML_HI_CNT=0
            [ "$ANML_LO_CNT" -lt 2 ] && echo 1 && return
        fi
    else
        ANML_HI_CNT=0; ANML_LO_CNT=0
    fi
    echo 0
}

# ═══════════════════════════════════════
# ██ AI SYSTEM 3: 2ND-ORDER THERMAL PREDICTOR ██
# Tracks temperature velocity AND acceleration.
# Projects temperature THERM_LOOKAHEAD seconds ahead.
# Acts before the threshold is hit, not after.
# ═══════════════════════════════════════
THERM_V=0       # velocity:     deg/sample
THERM_A=0       # acceleration: change in velocity
PREV_THERM_V=0  # previous velocity
PREV_TEMP=0; TEMP_SAMPLES=0

# All thermal zones, priority-ranked
TEMP_ZONES_SKIN=""
TEMP_ZONES_CPU=""
TEMP_ZONES_ALL=""

# Build zone priority lists once at startup
build_temp_zones() {
    for _z in /sys/class/thermal/thermal_zone*; do
        _tp=$(cat "$_z/type" 2>/dev/null); [ -z "$_tp" ] && continue
        case "$_tp" in
            *skin*|*xo_therm*|*quiet*|*pa_therm*)
                TEMP_ZONES_SKIN="$TEMP_ZONES_SKIN $_z";;
            *cpu*|*soc*|*tsens*|*big*|*cluster*|*mtktscpu*)
                TEMP_ZONES_CPU="$TEMP_ZONES_CPU $_z";;
        esac
        TEMP_ZONES_ALL="$TEMP_ZONES_ALL $_z"
    done
}

get_temp() {
    _best=0; _best_prio=0
    for _z in $TEMP_ZONES_SKIN $TEMP_ZONES_CPU; do
        _v=$(cat "$_z/temp" 2>/dev/null); [ -z "$_v" ] && continue
        [ "$_v" -gt 1000 ] && _v=$(( _v / 1000 ))
        [ "$_v" -le 0 ] || [ "$_v" -ge 125 ] && continue
        _tp=$(cat "$_z/type" 2>/dev/null)
        case "$_tp" in
            *skin*|*xo_therm*|*quiet*) _prio=3;;
            *cpu*|*soc*|*tsens*|*big*) _prio=2;;
            *)                          _prio=1;;
        esac
        if [ "$_prio" -gt "$_best_prio" ] || { [ "$_prio" -eq "$_best_prio" ] && [ "$_v" -gt "$_best" ]; }; then
            _best=$_v; _best_prio=$_prio
        fi
    done
    # Fallback: scan all zones
    if [ "$_best" -eq 0 ]; then
        for _z in $TEMP_ZONES_ALL; do
            _v=$(cat "$_z/temp" 2>/dev/null); [ -z "$_v" ] && continue
            [ "$_v" -gt 1000 ] && _v=$(( _v / 1000 ))
            [ "$_v" -le 0 ] || [ "$_v" -ge 125 ] && continue
            [ "$_v" -gt "$_best" ] && _best=$_v
        done
    fi
    [ "$_best" -eq 0 ] && _best=38
    echo "$_best"
}

# Updates velocity + acceleration + predicted temperature
TEMP_PRED=0     # predicted temp at lookahead
THERM_LVL="OK"; PREV_THERM_LVL="OK"

thermal_update() {
    _cur=$1
    TEMP_SAMPLES=$(( TEMP_SAMPLES + 1 ))

    if [ "$PREV_TEMP" -gt 0 ]; then
        _delta=$(( _cur - PREV_TEMP ))
        PREV_THERM_V=$THERM_V
        THERM_V=$(( (_delta * 7 + THERM_V * 3) / 10 ))   # EMA of velocity
        THERM_A=$(( THERM_V - PREV_THERM_V ))             # acceleration
    fi
    PREV_TEMP=$_cur

    # 2nd-order prediction:  T_pred = T + V*t + 0.5*A*t²
    _t=$THERM_LOOKAHEAD
    _vt=$(( THERM_V * _t ))
    _at=$(( THERM_A * _t * _t / 2 ))
    TEMP_PRED=$(( _cur + _vt + _at ))
    # Clamp prediction to sane range
    [ "$TEMP_PRED" -lt "$_cur" ] && TEMP_PRED=$_cur
    [ "$TEMP_PRED" -gt 100 ]    && TEMP_PRED=100

    PREV_THERM_LVL=$THERM_LVL

    # Decision uses PREDICTED temp, not current — act early
    _eff=$TEMP_PRED
    if   [ "$_eff" -ge "$THERMAL_EMERG" ]; then THERM_LVL="EMERGENCY"
    elif [ "$_eff" -ge "$THERMAL_CRIT"  ]; then
        [ "$THERM_LVL" = "EMERGENCY" ] && [ "$_eff" -ge $(( THERMAL_EMERG - THERMAL_HYST )) ] \
            && THERM_LVL="EMERGENCY" || THERM_LVL="CRITICAL"
    elif [ "$_eff" -ge "$THERMAL_HOT"   ]; then
        [ "$THERM_LVL" = "CRITICAL"  ] && [ "$_eff" -ge $(( THERMAL_CRIT  - THERMAL_HYST )) ] \
            && THERM_LVL="CRITICAL"  || THERM_LVL="HOT"
    elif [ "$_eff" -ge "$THERMAL_WARM"  ]; then
        [ "$THERM_LVL" = "HOT"       ] && [ "$_eff" -ge $(( THERMAL_HOT   - THERMAL_HYST )) ] \
            && THERM_LVL="HOT"       || THERM_LVL="WARM"
    elif [ "$_eff" -ge "$THERMAL_SAFE"  ]; then
        [ "$THERM_LVL" = "WARM"      ] && [ "$_eff" -ge $(( THERMAL_WARM  - THERMAL_HYST )) ] \
            && THERM_LVL="WARM"      || THERM_LVL="SAFE"
    else
        [ "$THERM_LVL" = "SAFE"      ] && [ "$_eff" -ge $(( THERMAL_SAFE  - THERMAL_HYST )) ] \
            && THERM_LVL="SAFE"      || THERM_LVL="OK"
    fi

    [ "$THERM_LVL" != "$PREV_THERM_LVL" ] && \
        log "THERM" "${PREV_THERM_LVL}->${THERM_LVL}  cur=${_cur}C pred=${TEMP_PRED}C v=${THERM_V} a=${THERM_A}"
}

# Thermal floor cap (how hard we compress the floor ceiling when hot)
therm_floor_cap() {
    case "$THERM_LVL" in
        OK|SAFE)   echo "$FLOOR_MAX_PCT";;
        WARM)      echo $(( FLOOR_MAX_PCT * 90 / 100 ));;
        HOT)       echo $(( FLOOR_MAX_PCT * 76 / 100 ));;
        CRITICAL)  echo $(( FLOOR_MAX_PCT * 58 / 100 ));;
        EMERGENCY) echo "$FLOOR_MIN_PCT";;
    esac
}

# CPU ceiling when thermally throttled (downward from stock only)
therm_ceil_pct() {
    case "$THERM_LVL" in
        OK|SAFE|WARM) echo 100;;
        HOT)          echo 87;;
        CRITICAL)     echo 68;;
        EMERGENCY)    echo 50;;
    esac
}

# ═══════════════════════════════════════
# ██ AI SYSTEM 4: WORKLOAD STATE MACHINE ██
# Classifies what the game is doing right now
# from multi-signal patterns. Used to pre-adjust
# floor before FPS drop is observed.
# States: MENU  LOADING  LIGHT  MEDIUM  HEAVY  INTENSE
# ═══════════════════════════════════════
WLOAD="MEDIUM"; PREV_WLOAD="MEDIUM"; WLOAD_HOLD=0

workload_update() {
    _cu=$1; _gl=$2; _fps=$3; _var=$4
    _combined=$(( _cu + _gl ))

    # FPS-based override first (most reliable signal)
    if   [ "$_fps" -ge 0 ] && [ "$_fps" -lt $(( TARGET_FPS * 40 / 100 )) ]; then
        _ns="LOADING"     # very low FPS = loading screen
    elif [ "$_fps" -ge 0 ] && [ "$_fps" -lt $(( TARGET_FPS - FPS_CRIT_DROP )) ]; then
        _ns="INTENSE"     # fps below target = intense scene
    elif [ "$_combined" -ge 185 ]; then
        _ns="INTENSE"
    elif [ "$_combined" -ge 155 ]; then
        _ns="HEAVY"
    elif [ "$_combined" -ge 115 ]; then
        _ns="MEDIUM"
    elif [ "$_combined" -ge 70 ]; then
        _ns="LIGHT"
    else
        _ns="MENU"
    fi

    # High FPS variance with moderate load = unstable MEDIUM
    [ "$_var" -gt 80 ] && [ "$_ns" = "MEDIUM" ] && _ns="HEAVY"

    # Anti-flicker: hold state for 2 cycles before switching
    if [ "$_ns" = "$PREV_WLOAD" ]; then
        WLOAD_HOLD=0; WLOAD=$_ns
    else
        WLOAD_HOLD=$(( WLOAD_HOLD + 1 ))
        if [ "$WLOAD_HOLD" -ge 2 ]; then
            [ "$WLOAD" != "$_ns" ] && log "WLOAD" "${WLOAD}->${_ns}  CPU=${_cu} GPU=${_gl} FPS=${_fps}" 2
            WLOAD=$_ns; PREV_WLOAD=$_ns; WLOAD_HOLD=0
        fi
    fi
}

# Floor multiplier per workload state
wload_floor_mult() {
    case "$WLOAD" in
        LOADING)  echo 72;;   # hold floor during loads to avoid stutter on entry
        MENU)     echo 55;;   # light work
        LIGHT)    echo 80;;
        MEDIUM)   echo 100;;
        HEAVY)    echo 115;;
        INTENSE)  echo 128;;  # max headroom for intense scenes
    esac
}

wload_gpu_mult() {
    case "$WLOAD" in
        LOADING)  echo 68;;
        MENU)     echo 50;;
        LIGHT)    echo 78;;
        MEDIUM)   echo 100;;
        HEAVY)    echo 112;;
        INTENSE)  echo 122;;
    esac
}

# ═══════════════════════════════════════
# ██ AI SYSTEM 5: SELF-TUNING PID ██
# Tracks long-term tracking error variance.
# If consistently oscillating → lower KP.
# If consistently sluggish → raise KP.
# Runs every 100 cycles so it's gradual.
# ═══════════════════════════════════════
PID_PE=0; PID_IS=0; PID_PO=0
TUNE_ERR_SUM=0; TUNE_ERR_SQ=0; TUNE_N=0
TUNE_CYCLES=0

pid_floor_step() {
    _fps=$1; _tgt=$2
    [ "$_fps" -lt 0 ] && echo "$PID_PO" && return

    _err=$(( _tgt - _fps ))

    # Asymmetric P: 3× harder on drops than overshoots
    if [ "$_err" -gt 0 ]; then _p=$(( KP * _err * 20 / 100 ))
    else                        _p=$(( KP * _err *  6 / 100 ))
    fi

    # Integral with anti-windup + sign-flip partial reset
    PID_IS=$(( PID_IS + _err ))
    [ "$PID_IS" -gt  "$I_CLAMP" ] && PID_IS=$I_CLAMP
    [ "$PID_IS" -lt "-$I_CLAMP" ] && PID_IS=-$I_CLAMP
    [ "$_err" -gt 2  ] && [ "$PID_PE" -lt -2 ] && PID_IS=$(( PID_IS / 4 ))
    [ "$_err" -lt -2 ] && [ "$PID_PE" -gt  2 ] && PID_IS=$(( PID_IS / 4 ))
    _i=$(( KI * PID_IS / 10 ))

    # Derivative (damps oscillation)
    _d=$(( KD * (_err - PID_PE) / 10 ))
    PID_PE=$_err

    _out=$(( _p + _i + _d ))

    # Rate limiter: no sudden floor jumps
    _diff=$(( _out - PID_PO ))
    [ "$_diff" -gt  "$RATE_LIMIT" ] && _out=$(( PID_PO + RATE_LIMIT ))
    [ "$_diff" -lt "-$RATE_LIMIT" ] && _out=$(( PID_PO - RATE_LIMIT ))

    PID_PO=$_out

    # Self-tuning data collection
    if [ "$AI_SELF_TUNE" = "1" ]; then
        TUNE_ERR_SUM=$(( TUNE_ERR_SUM + _err ))
        TUNE_ERR_SQ=$(( TUNE_ERR_SQ + _err * _err ))
        TUNE_N=$(( TUNE_N + 1 ))
        TUNE_CYCLES=$(( TUNE_CYCLES + 1 ))
        [ "$TUNE_CYCLES" -ge 100 ] && _pid_self_tune
    fi

    echo "$_out"
}

_pid_self_tune() {
    [ "$TUNE_N" -le 0 ] && { TUNE_CYCLES=0; return; }

    # Mean absolute error
    _mae=$(( TUNE_ERR_SUM / TUNE_N ))
    [ "$_mae" -lt 0 ] && _mae=$(( -_mae ))

    # Variance = E[err²] - E[err]²
    _mean=$(( TUNE_ERR_SUM / TUNE_N ))
    _var=$(( TUNE_ERR_SQ / TUNE_N - _mean * _mean ))
    [ "$_var" -lt 0 ] && _var=0

    # High variance = oscillating → soften KP
    if [ "$_var" -gt 100 ] && [ "$KP" -gt 8 ]; then
        KP=$(( KP - 1 ))
        log "TUNE" "Oscillation detected var=$_var → KP reduced to $KP" 2
    fi

    # Consistently negative mean = always above target → reduce I
    if [ "$_mean" -lt -6 ] && [ "$KI" -gt 1 ]; then
        KI=$(( KI - 1 ))
        log "TUNE" "Overshoot bias → KI reduced to $KI" 2
    fi

    # Consistently positive mean = always below target → increase P
    if [ "$_mean" -gt 8 ] && [ "$KP" -lt 30 ]; then
        KP=$(( KP + 1 ))
        log "TUNE" "Undershoot bias MAE=$_mae → KP raised to $KP" 2
    fi

    # Save tuned gains to AI state file
    printf "KP=%s\nKI=%s\nKD=%s\n" "$KP" "$KI" "$KD" > "$AI_DIR/pid_gains.state"

    TUNE_ERR_SUM=0; TUNE_ERR_SQ=0; TUNE_N=0; TUNE_CYCLES=0
}

# Load previously tuned gains if they exist
ai_load_gains() {
    _gf="$AI_DIR/pid_gains.state"
    [ -f "$_gf" ] && . "$_gf" && log "AI" "Loaded tuned gains KP=$KP KI=$KI KD=$KD"
}

# ═══════════════════════════════════════
# ██ AI SYSTEM 6: SMOOTH SCORE ██
# Running smoothness score 0–100.
# Combines FPS stability + jank rate + variance.
# Logged every 10 cycles as health indicator.
# ═══════════════════════════════════════
SMOOTH_SCORE=100
SMOOTH_JANK_ACC=0
SMOOTH_SAMPLES=0

smooth_update() {
    _fps=$1; _tgt=$2; _var=$3; _jd=$4
    SMOOTH_SAMPLES=$(( SMOOTH_SAMPLES + 1 ))

    # FPS deviation penalty (0–40 pts)
    _fdiff=$(( _tgt - _fps ))
    [ "$_fdiff" -lt 0 ] && _fdiff=0
    _fps_pen=$(( _fdiff * 4 ))
    [ "$_fps_pen" -gt 40 ] && _fps_pen=40

    # Variance penalty (0–30 pts)
    _var_pen=$(( _var / 5 ))
    [ "$_var_pen" -gt 30 ] && _var_pen=30

    # Jank penalty (0–30 pts)
    SMOOTH_JANK_ACC=$(( SMOOTH_JANK_ACC + _jd ))
    _jank_pen=$(( SMOOTH_JANK_ACC / SMOOTH_SAMPLES ))
    [ "$_jank_pen" -gt 30 ] && _jank_pen=30

    _raw_score=$(( 100 - _fps_pen - _var_pen - _jank_pen ))
    [ "$_raw_score" -lt 0   ] && _raw_score=0
    [ "$_raw_score" -gt 100 ] && _raw_score=100

    # EMA the score itself for stability
    SMOOTH_SCORE=$(( (3 * _raw_score + 7 * SMOOTH_SCORE) / 10 ))
}

# ═══════════════════════════════════════
# FPS MONITORING (ring buffer)
# ═══════════════════════════════════════
PREV_FC=0; PREV_FT=0; PREV_JANK=0
FPS_BUF=""; FPS_CNT=0; FPS_RING=14

get_fps() {
    _now=$(date +%s)
    # Method 1: per-app gfxinfo (most accurate)
    if [ -n "$CUR_APP" ]; then
        _fc=$(dumpsys gfxinfo "$CUR_APP" 2>/dev/null | grep "Total frames rendered" | head -1 | tr -dc '0-9')
        if [ -n "$_fc" ] && [ "$PREV_FC" -gt 0 ] && [ "$PREV_FT" -gt 0 ]; then
            _dt=$(( _now - PREV_FT )); [ "$_dt" -le 0 ] && _dt=1
            _df=$(( _fc  - PREV_FC )); [ "$_df" -lt 0 ] && _df=0
            _fps=$(( _df / _dt ))
            [ "$_fps" -gt "$TARGET_FPS_HARD" ] && _fps=$TARGET_FPS_HARD
            PREV_FC=$_fc; PREV_FT=$_now; echo "$_fps"; return
        fi
        [ -n "$_fc" ] && { PREV_FC=$_fc; PREV_FT=$_now; }
    fi
    # Method 2: SurfaceFlinger global
    _fc=$(dumpsys SurfaceFlinger --latency 2>/dev/null | tail -n +2 | grep -cE '^[0-9]')
    if [ -n "$_fc" ] && [ "$_fc" -gt 0 ] && [ "$PREV_FC" -gt 0 ] && [ "$PREV_FT" -gt 0 ]; then
        _dt=$(( _now - PREV_FT )); [ "$_dt" -le 0 ] && _dt=1
        _df=$(( _fc  - PREV_FC )); [ "$_df" -lt 0 ] && _df=0
        _fps=$(( _df / _dt ))
        [ "$_fps" -gt "$TARGET_FPS_HARD" ] && _fps=$TARGET_FPS_HARD
        PREV_FC=$_fc; PREV_FT=$_now; echo "$_fps"; return
    fi
    [ -n "$_fc" ] && [ "$_fc" -gt 0 ] && { PREV_FC=$_fc; PREV_FT=$_now; }
    echo "-1"
}

fps_add() {
    FPS_BUF="$FPS_BUF $1"; FPS_CNT=$(( FPS_CNT + 1 ))
    [ "$FPS_CNT" -gt "$FPS_RING" ] && {
        _k=$(( FPS_RING - 1 ))
        FPS_BUF=$(echo $FPS_BUF | awk -v k=$_k '{for(i=NF-k+1;i<=NF;i++) printf $i" "}')
        FPS_CNT=$_k
    }
}

fps_avg() {
    _s=0; _c=0
    for _v in $FPS_BUF; do _s=$(( _s+_v )); _c=$(( _c+1 )); done
    [ "$_c" -eq 0 ] && echo -1 || echo $(( _s / _c ))
}

fps_min_recent() {
    _m=9999
    for _v in $FPS_BUF; do [ "$_v" -lt "$_m" ] && _m=$_v; done
    [ "$_m" -eq 9999 ] && echo -1 || echo "$_m"
}

fps_variance() {
    _avg=$(fps_avg); [ "$_avg" -le 0 ] && echo 0 && return
    _sq=0; _c=0
    for _v in $FPS_BUF; do
        _d=$(( _v - _avg )); _sq=$(( _sq + _d*_d )); _c=$(( _c+1 ))
    done
    [ "$_c" -eq 0 ] && echo 0 || echo $(( _sq / _c ))
}

get_jank() {
    [ -z "$CUR_APP" ] && echo 0 && return
    _j=$(dumpsys gfxinfo "$CUR_APP" 2>/dev/null | grep "Janky frames" | head -1 | tr -dc '0-9 ' | awk '{print $1}')
    echo "${_j:-0}"
}

# ═══════════════════════════════════════
# STUTTER DETECTOR
# ═══════════════════════════════════════
STUT_CNT=0; STUT_DECAY=0

stutter_update() {
    _fps=$1; _ema=$2; _jd=$3
    [ "$_ema" -gt 0 ] && [ $(( _ema - _fps )) -gt "$FPS_STUTTER_THRESH" ] && STUT_CNT=$(( STUT_CNT + 1 ))
    [ "$_jd"  -gt 4 ] && STUT_CNT=$(( STUT_CNT + 1 ))
    STUT_DECAY=$(( STUT_DECAY + 1 ))
    [ "$STUT_DECAY" -ge 8 ] && {
        [ "$STUT_CNT" -gt 0 ] && STUT_CNT=$(( STUT_CNT - 1 ))
        STUT_DECAY=0
    }
}

stutter_bonus() {
    [ "$STUT_CNT" -ge 2 ] && {
        _b=$(( STUT_CNT * 3 )); [ "$_b" -gt 15 ] && _b=15; echo "$_b"; return
    }
    echo 0
}

# ═══════════════════════════════════════
# APP & GAME DETECTION
# ═══════════════════════════════════════
CUR_APP=""; IS_GAME=0; GL=50

detect_app() {
    _app=$(dumpsys activity activities 2>/dev/null \
        | grep -m1 "topResumedActivity\|mResumedActivity" \
        | grep -oE '[a-zA-Z][a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' | head -1 | cut -d'/' -f1)
    [ -z "$_app" ] && _app=$(dumpsys window windows 2>/dev/null \
        | grep -m1 "mCurrentFocus\|mFocusedApp" \
        | grep -oE '[a-zA-Z][a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' | head -1 | cut -d'/' -f1)
    CUR_APP="$_app"; IS_GAME=0; [ -z "$_app" ] && return

    # Whitelist match
    for _pkg in $GAME_LIST; do
        case "$_app" in *${_pkg}*) IS_GAME=1; return;; esac
    done
    # Android category
    _cat=$(dumpsys package "$_app" 2>/dev/null | grep -i "category" | head -1)
    case "$_cat" in *game*|*GAME*) IS_GAME=1; log "DETECT" "Category: $_app"; return;; esac
    # Heuristic: GPU renderer
    [ "${GL:-0}" -ge 55 ] && {
        _rend=$(dumpsys gfxinfo "$_app" 2>/dev/null | grep -iE "renderer|Vulkan|OpenGL" | head -1)
        case "$_rend" in *GL*|*Vulkan*|*vulkan*) IS_GAME=1; log "DETECT" "Heuristic: $_app GPU=$GL";; esac
    }
}

# ═══════════════════════════════════════
# PER-GAME DEEP PROFILES
# Stores: floor_bias, avg_cpu, avg_gpu,
#         avg_fps_var, preferred_wload_floor,
#         total_sessions, self-tuned KP
# ═══════════════════════════════════════
G_FLOOR_BIAS=0; G_CYCLES=0
G_AVG_CPU=50; G_AVG_GPU=50; G_AVG_VAR=20
G_SESSIONS=0

prof_load() {
    _pf="$PROF_DIR/${1}.prof"
    if [ -f "$_pf" ]; then
        . "$_pf"
        G_FLOOR_BIAS=${P_FB:-0}
        G_CYCLES=${P_CY:-0}
        G_AVG_CPU=${P_AC:-50}
        G_AVG_GPU=${P_AG:-50}
        G_AVG_VAR=${P_AV:-20}
        G_SESSIONS=${P_SS:-0}
        log "PROF" "Load $1  bias=$G_FLOOR_BIAS ac=${G_AVG_CPU} ag=${G_AVG_GPU} av=${G_AVG_VAR} sess=$G_SESSIONS"
    else
        G_FLOOR_BIAS=0; G_CYCLES=0
        G_AVG_CPU=50; G_AVG_GPU=50; G_AVG_VAR=20; G_SESSIONS=0
        log "PROF" "New game: $1"
    fi
}

prof_save() {
    [ -z "$1" ] && return
    G_SESSIONS=$(( G_SESSIONS + 1 ))
    printf "P_FB=%s\nP_CY=%s\nP_AC=%s\nP_AG=%s\nP_AV=%s\nP_SS=%s\n" \
        "$G_FLOOR_BIAS" "$G_CYCLES" \
        "$G_AVG_CPU" "$G_AVG_GPU" "$G_AVG_VAR" "$G_SESSIONS" \
        > "$PROF_DIR/${1}.prof"
}

prof_learn() {
    _fps=$1; _tgt=$2; _temp=$3; _cu=$4; _gl=$5; _var=$6
    G_CYCLES=$(( G_CYCLES + 1 ))

    # Update running averages (EMA-style)
    G_AVG_CPU=$(( (3*_cu  + 7*G_AVG_CPU) / 10 ))
    G_AVG_GPU=$(( (3*_gl  + 7*G_AVG_GPU) / 10 ))
    G_AVG_VAR=$(( (3*_var + 7*G_AVG_VAR) / 10 ))

    # Learn floor bias every 20 cycles
    [ $(( G_CYCLES % 20 )) -ne 0 ] && return

    _err=$(( _tgt - _fps ))

    # Raise bias: fps consistently below target AND not thermal-limited
    if   [ "$_err" -gt 8 ] && [ "$_temp" -lt "$THERMAL_WARM" ]; then
        [ "$G_FLOOR_BIAS" -lt 18 ] && G_FLOOR_BIAS=$(( G_FLOOR_BIAS + 2 ))
    elif [ "$_err" -gt 3 ] && [ "$_temp" -lt "$THERMAL_SAFE" ]; then
        [ "$G_FLOOR_BIAS" -lt 18 ] && G_FLOOR_BIAS=$(( G_FLOOR_BIAS + 1 ))
    fi

    # Lower bias: fps well above target (we're wasting floor headroom)
    [ "$_err" -lt -10 ] && [ "$G_FLOOR_BIAS" -gt -8 ] && G_FLOOR_BIAS=$(( G_FLOOR_BIAS - 1 ))

    # Decay toward 0 when stable (self-correcting)
    if [ "$_err" -ge -3 ] && [ "$_err" -le 3 ]; then
        [ "$G_FLOOR_BIAS" -gt 0 ] && G_FLOOR_BIAS=$(( G_FLOOR_BIAS - 1 ))
        [ "$G_FLOOR_BIAS" -lt 0 ] && G_FLOOR_BIAS=$(( G_FLOOR_BIAS + 1 ))
    fi

    # Thermal hard cap on learned bias
    [ "$_temp" -ge "$THERMAL_HOT" ] && [ "$G_FLOOR_BIAS" -gt 3 ] && G_FLOOR_BIAS=3

    prof_save "$CUR_APP"
}

# ═══════════════════════════════════════
# SYSTEM METRICS
# ═══════════════════════════════════════
PT=0; PIS=0

cpu_load() {
    read _cpu _u _n _s _i _io _ir _so _st < /proc/stat
    _tot=$(( _u+_n+_s+_i+_io+_ir+_so+_st ))
    [ "$PT" -eq 0 ] && { PT=$_tot; PIS=$_i; echo 0; return; }
    _dt=$(( _tot-PT )); _di=$(( _i-PIS )); PT=$_tot; PIS=$_i
    [ "$_dt" -le 0 ] && echo 0 || echo $(( 100*(_dt-_di)/_dt ))
}

get_batt()    { _b=$(cat /sys/class/power_supply/*/capacity 2>/dev/null | head -n1); echo "${_b:-50}"; }
is_charging() {
    _s=$(cat /sys/class/power_supply/*/status 2>/dev/null | head -n1)
    case "$_s" in *harging) echo 1;; *) echo 0;; esac
}
get_screen() {
    _s=$(dumpsys power 2>/dev/null | grep -m1 "mWakefulness\|Display Power")
    case "$_s" in *Awake*|*ON*|*on*) echo 1;; *) echo 0;; esac
}
mem_press() {
    if [ -f /proc/pressure/memory ]; then
        _a=$(cat /proc/pressure/memory 2>/dev/null | head -1 | grep -oE 'avg10=[0-9.]+' | cut -d= -f2 | cut -d. -f1)
        [ -z "$_a" ] && echo 0 && return
        [ "$_a" -ge 30 ] && echo 3 || { [ "$_a" -ge 15 ] && echo 2 || { [ "$_a" -ge 5 ] && echo 1 || echo 0; }; }
    else
        _av=$(grep MemAvailable /proc/meminfo 2>/dev/null | tr -dc '0-9')
        _tt=$(grep MemTotal     /proc/meminfo 2>/dev/null | tr -dc '0-9')
        [ -z "$_av" ] || [ -z "$_tt" ] || [ "$_tt" -eq 0 ] && echo 0 && return
        _pct=$(( 100 * _av / _tt ))
        [ "$_pct" -le 10 ] && echo 3 || { [ "$_pct" -le 20 ] && echo 2 || { [ "$_pct" -le 35 ] && echo 1 || echo 0; }; }
    fi
}
io_press() {
    [ -f /proc/pressure/io ] || { echo 0; return; }
    _a=$(cat /proc/pressure/io 2>/dev/null | head -1 | grep -oE 'avg10=[0-9.]+' | cut -d= -f2 | cut -d. -f1)
    [ -z "$_a" ] && echo 0 && return
    [ "$_a" -ge 20 ] && echo 2 || { [ "$_a" -ge 8 ] && echo 1 || echo 0; }
}

# ═══════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════
detect_gpu
detect_tier
cluster_init
build_temp_zones
set_gov
ai_load_gains

# Auto-detect target FPS
[ "$TARGET_FPS" -eq 0 ] && {
    TARGET_FPS=$(detect_display_fps)
    log "INIT" "Display: ${TARGET_FPS}Hz auto-detected"
}
TARGET_FPS_HARD=$TARGET_FPS

FLOOR_CPU=$BASE_FLOOR_CPU
FLOOR_GPU=$BASE_FLOOR_GPU

log "INIT" "Target=${TARGET_FPS}fps  GPU=$GPU_TYPE  TIER=$TIER  KP=$KP KI=$KI KD=$KD  FLOOR_MAX=${FLOOR_MAX_PCT}%"

# ═══════════════════════════════════════
# LOOP STATE
# ═══════════════════════════════════════
MODE="IDLE"; PREV_APP=""
CYCLE=0; PREV_JANK=0
COOL_ACTIVE=0; COOL_UNTIL=0
AFPS=-1; FMIN=-1; FVAR=0; ETGT=$TARGET_FPS

log "LOOP" "Main loop started  AI systems: EMA PredThermal WorkloadSM SelfPID AnomalyFilter SmoothScore"

# ═══════════════════════════════════════
# ██ MAIN LOOP ██
# ═══════════════════════════════════════
while true; do

    # ── Screen off: deep idle, full hardware restore ──
    if [ "$(get_screen)" = "0" ]; then
        if [ "$MODE" != "SCREEN_OFF" ]; then
            [ -n "$PREV_APP" ] && prof_save "$PREV_APP"
            cpu_restore_all; gpu_restore; set_gov
            FLOOR_CPU=$BASE_FLOOR_CPU; FLOOR_GPU=$BASE_FLOOR_GPU
            PID_IS=0; PID_PE=0; PID_PO=0
            EMA_FPS=-1; EMA_INIT=0
            FPS_BUF=""; FPS_CNT=0; STUT_CNT=0
            SMOOTH_SCORE=100; SMOOTH_JANK_ACC=0; SMOOTH_SAMPLES=0
            MODE="SCREEN_OFF"; PREV_APP=""
            log "SCRN" "Screen off — deep idle"
        fi
        sleep "$SCREEN_OFF_SLEEP"; continue
    fi

    detect_app

    # ════════════════════════════════════════════
    # GAME MODE  — all AI systems active
    # ════════════════════════════════════════════
    if [ "$IS_GAME" -eq 1 ] && [ -n "$CUR_APP" ]; then

        # ── New game session: full state reset ──
        if [ "$CUR_APP" != "$PREV_APP" ]; then
            prof_load "$CUR_APP"
            PREV_APP="$CUR_APP"
            PID_IS=0; PID_PE=0; PID_PO=0
            PREV_FC=0; PREV_FT=0; PREV_JANK=0
            EMA_FPS=-1; EMA_INIT=0; ANML_HI_CNT=0; ANML_LO_CNT=0
            FPS_BUF=""; FPS_CNT=0
            STUT_CNT=0; STUT_DECAY=0
            THERM_V=0; THERM_A=0; PREV_THERM_V=0; PREV_TEMP=0; TEMP_SAMPLES=0
            WLOAD="MEDIUM"; PREV_WLOAD="MEDIUM"; WLOAD_HOLD=0
            SMOOTH_SCORE=100; SMOOTH_JANK_ACC=0; SMOOTH_SAMPLES=0
            TUNE_ERR_SUM=0; TUNE_ERR_SQ=0; TUNE_N=0; TUNE_CYCLES=0
            COOL_ACTIVE=0; MODE="GAMING"
            # Pre-warm floor from learned bias
            FLOOR_CPU=$(( BASE_FLOOR_CPU + G_FLOOR_BIAS ))
            FLOOR_GPU=$(( BASE_FLOOR_GPU + G_FLOOR_BIAS * 8 / 10 ))
            cpu_set_floor "$FLOOR_CPU"; gpu_set_floor "$FLOOR_GPU"
            log "GAME" "=== Session: $CUR_APP  floor=CPU${FLOOR_CPU}% GPU${FLOOR_GPU}% sess=$G_SESSIONS ==="
            sleep 1; continue
        fi

        # ── Post-emergency cooldown ──
        _now_s=$(date +%s)
        if [ "$COOL_ACTIVE" -eq 1 ]; then
            [ "$_now_s" -lt "$COOL_UNTIL" ] && { sleep 2; continue; }
            COOL_ACTIVE=0; log "COOL" "Cooldown complete"
        fi

        # ═══════════════════════════════
        # COLLECT ALL METRICS
        # ═══════════════════════════════
        TEMP=$(get_temp)
        CU=$(cpu_load)
        GL=$(gpu_load)
        BATT=$(get_batt)
        CHRG=$(is_charging)
        FPS=$(get_fps)
        MP=$(mem_press)
        IOP=$(io_press)

        # ═══════════════════════════════
        # AI: THERMAL PREDICTOR
        # ═══════════════════════════════
        thermal_update "$TEMP"
        THERM_FCAP=$(therm_floor_cap)
        THERM_CCEIL=$(therm_ceil_pct)

        # ── EMERGENCY: restore + extended pause ──
        if [ "$THERM_LVL" = "EMERGENCY" ]; then
            cpu_restore_all; gpu_restore; set_gov
            COOL_ACTIVE=1; COOL_UNTIL=$(( _now_s + 18 ))
            FLOOR_CPU=$BASE_FLOOR_CPU; FLOOR_GPU=$BASE_FLOOR_GPU
            PID_IS=0; PID_PE=0; PID_PO=0; PREV_FC=0; PREV_FT=0
            log "EMERG" "T=${TEMP}C pred=${TEMP_PRED}C v=${THERM_V} — restored + 18s pause"
            sleep 3; continue
        fi

        # Thermal ceiling (downward only — never above stock)
        if [ "$THERM_CCEIL" -lt 100 ]; then
            cpu_throttle_ceil "$THERM_CCEIL"
            gpu_throttle_ceil "$THERM_CCEIL"
        else
            for _p in $POLICY_LIST; do
                _hw=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null); [ -n "$_hw" ] && write "$_p/scaling_max_freq" "$_hw"
            done
        fi

        # ═══════════════════════════════
        # AI: EMA SMOOTHER + ANOMALY FILTER
        # ═══════════════════════════════
        _fps_valid=0
        if [ "$FPS" -ge 0 ]; then
            # Run anomaly check before updating EMA
            _is_anomaly=$(anomaly_check "$FPS")
            if [ "$_is_anomaly" = "0" ]; then
                ema_update "$FPS"
                fps_add "$FPS"
                _fps_valid=1
            fi
            AFPS=$(fps_avg); FMIN=$(fps_min_recent); FVAR=$(fps_variance)
            CJ=$(get_jank); JD=$(( CJ - PREV_JANK ))
            [ "$JD" -lt 0 ] && JD=0; PREV_JANK=$CJ
            stutter_update "$FPS" "$EMA_FPS" "$JD"
            smooth_update "$FPS" "$ETGT" "$FVAR" "$JD"
        else
            AFPS=-1; FMIN=-1; FVAR=0; JD=0
        fi

        # ═══════════════════════════════
        # AI: WORKLOAD STATE MACHINE
        # ═══════════════════════════════
        workload_update "$CU" "$GL" "$FPS" "$FVAR"
        WL_CPU_MULT=$(wload_floor_mult)
        WL_GPU_MULT=$(wload_gpu_mult)

        # ═══════════════════════════════
        # BATTERY-AWARE TARGET FPS
        # ═══════════════════════════════
        ETGT=$TARGET_FPS
        [ "$BATT" -le "$BATT_LOW" ] && [ "$CHRG" -eq 0 ] && ETGT=$(( TARGET_FPS - 14 ))
        [ "$BATT" -le "$BATT_MED" ] && [ "$BATT" -gt "$BATT_LOW" ] && [ "$CHRG" -eq 0 ] && ETGT=$(( TARGET_FPS - 6 ))
        [ "$ETGT" -lt 24 ] && ETGT=24

        # ═══════════════════════════════
        # AI: SELF-TUNING PID  (uses EMA FPS for clean signal)
        # ═══════════════════════════════
        if [ "$_fps_valid" = "1" ] && [ "$EMA_INIT" = "1" ]; then
            POUT=$(pid_floor_step "$EMA_FPS" "$ETGT")
        elif [ "$FPS" -ge 0 ]; then
            POUT=$(pid_floor_step "$FPS" "$ETGT")
        else
            # No FPS: load-based fallback
            POUT=0
            [ "$CU" -ge 80 ] && POUT=$(( POUT + 6 ))
            [ "$GL" -ge 80 ] && POUT=$(( POUT + 5 ))
        fi
#made by: mrk/gellado/yubk
        # ═══════════════════════════════
        # COMPUTE FLOOR
        # ═══════════════════════════════
        _sb=$(stutter_bonus)
        _mp_bonus=0; [ "$MP" -ge 2 ] && _mp_bonus=4; [ "$MP" -ge 3 ] && _mp_bonus=7
        _io_bonus=0; [ "$IOP" -ge 2 ] && _io_bonus=2

        # Base + learned bias + PID adjustment
        FLOOR_CPU=$(( BASE_FLOOR_CPU + G_FLOOR_BIAS + POUT + _sb + _mp_bonus + _io_bonus ))
        FLOOR_GPU=$(( BASE_FLOOR_GPU + G_FLOOR_BIAS + (POUT + _sb) * 85 / 100 ))

        # Workload state machine scaling
        FLOOR_CPU=$(( FLOOR_CPU * WL_CPU_MULT / 100 ))
        FLOOR_GPU=$(( FLOOR_GPU * WL_GPU_MULT / 100 ))

        # Battery reduction
        if   [ "$BATT" -le "$BATT_LOW" ] && [ "$CHRG" -eq 0 ]; then
            FLOOR_CPU=$(( FLOOR_CPU - 9 )); FLOOR_GPU=$(( FLOOR_GPU - 7 ))
        elif [ "$BATT" -le "$BATT_MED" ] && [ "$CHRG" -eq 0 ]; then
            FLOOR_CPU=$(( FLOOR_CPU - 4 )); FLOOR_GPU=$(( FLOOR_GPU - 3 ))
        fi

        # Clamp within thermal-adjusted range
        [ "$FLOOR_CPU" -gt "$THERM_FCAP"       ] && FLOOR_CPU=$THERM_FCAP
        [ "$FLOOR_CPU" -lt "$FLOOR_MIN_PCT"     ] && FLOOR_CPU=$FLOOR_MIN_PCT
        [ "$FLOOR_GPU" -gt "$THERM_FCAP"        ] && FLOOR_GPU=$THERM_FCAP
        [ "$FLOOR_GPU" -lt "$GPU_FLOOR_MIN_PCT" ] && FLOOR_GPU=$GPU_FLOOR_MIN_PCT

        # ═══════════════════════════════
        # APPLY
        # ═══════════════════════════════
        cpu_set_floor "$FLOOR_CPU"
        gpu_set_floor "$FLOOR_GPU"

        # ═══════════════════════════════
        # AI: DEEP PROFILE LEARNING
        # ═══════════════════════════════
        [ "$FPS" -ge 0 ] && prof_learn "$FPS" "$ETGT" "$TEMP" "$CU" "$GL" "$FVAR"

        # ═══════════════════════════════
        # ADAPTIVE LOOP SPEED
        # Proportional to urgency — not binary
        # ═══════════════════════════════
        _drop=$(( ETGT - FPS ))
        if   [ "$FPS" -ge 0 ] && [ "$_drop" -gt "$FPS_CRIT_DROP" ]; then SLP=0.15
        elif [ "$FPS" -ge 0 ] && [ "$_drop" -gt "$FPS_DROP_REACT" ]; then SLP=0.35
        elif [ "$STUT_CNT"  -ge 3 ];                                   then SLP=0.3
        elif [ "$FVAR"      -gt 60 ];                                   then SLP=0.45
        elif [ "$WLOAD"     = "INTENSE" ];                              then SLP=0.4
        else                                                                  SLP=1.0
        fi

        # ═══════════════════════════════
        # LOGGING
        # ═══════════════════════════════
        CYCLE=$(( CYCLE + 1 ))
        [ $(( CYCLE % 5  )) -eq 0 ] && \
            log "RUN" "FPS=${FPS}(ema=${EMA_FPS} avg=${AFPS} min=${FMIN}) T=${TEMP}C(pred=${TEMP_PRED} ${THERM_LVL}) FLOOR=C${FLOOR_CPU}%/G${FLOOR_GPU}% WL=${WLOAD} PID=${POUT} stut=${STUT_CNT} sc=${SMOOTH_SCORE} bat=${BATT}%$([ "$CHRG" -eq 1 ] && echo +) M=${MP} IO=${IOP} bias=${G_FLOOR_BIAS}"
        [ $(( CYCLE % 60 )) -eq 0 ] && log_trim

        sleep "$SLP"

    # ════════════════════════════════════════════
    # NON-GAME FOREGROUND: static warm floor for UI
    # ════════════════════════════════════════════
    elif [ "$NON_GAME_FLOOR" = "1" ] && [ -n "$CUR_APP" ]; then
        if [ "$MODE" != "APP" ] || [ "$CUR_APP" != "$PREV_APP" ]; then
            cpu_restore_all; gpu_restore; set_gov
            cpu_set_floor 26; gpu_set_floor 20
            MODE="APP"; PREV_APP="$CUR_APP"
            log "APP" "UI floor: $CUR_APP"
        fi
        sleep 4

    # ════════════════════════════════════════════
    # IDLE: full hardware restore
    # ════════════════════════════════════════════
    else
        if [ "$MODE" != "IDLE" ]; then
            [ -n "$PREV_APP" ] && { prof_save "$PREV_APP"; log "PROF" "Saved $PREV_APP"; }
            cpu_restore_all; gpu_restore; set_gov
            PID_IS=0; PID_PE=0; PID_PO=0
            EMA_FPS=-1; EMA_INIT=0
            STUT_CNT=0; STUT_DECAY=0; FPS_BUF=""; FPS_CNT=0; COOL_ACTIVE=0
            FLOOR_CPU=$BASE_FLOOR_CPU; FLOOR_GPU=$BASE_FLOOR_GPU
            MODE="IDLE"; PREV_APP=""
            log "IDLE" "All systems reset"
        fi
        sleep "$IDLE_SLEEP"
    fi

done
