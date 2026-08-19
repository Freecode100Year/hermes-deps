#!/usr/bin/env bash
#
# hermes-preflight.sh -- Hermes Agent 依赖预装 / 体检脚本
#
# 目标：在正式执行官方安装器之前，把 Hermes Agent 需要的所有依赖装齐并实测验证，
#       让正式安装时每个检测点都命中「已存在 -> 跳过」，避免半路失败。
#
# 覆盖范围：apt 系（Debian 11/12/13、Ubuntu）。仅 CLI / 服务端，不含 Electron 桌面版依赖。
#
# 用法：
#   bash hermes-preflight.sh --check          # 只检测，不改动系统
#   sudo bash hermes-preflight.sh             # 装齐依赖
#   sudo bash hermes-preflight.sh --yes       # 非交互
#
# 退出码：0 = 全部就绪 / 1 = 致命失败 / 2 = 完成但有警告
#
set -uo pipefail

VERSION="1.0.0"

# ---------------------------------------------------------------- 可调参数 ----

NODE_MIN="22.22.0"                 # Hermes 要求的 Node 下限（react-router 8.3 强制）
NODE_CANDIDATES="24 22"            # 自动降级顺序：先试新的，跑不起来就退
NPM_BAD_LO="11.10.0"               # install.sh 拒绝的 npm 区间 [LO, HI)
NPM_BAD_HI="11.17.0"
NPM_SAFE="11.9.2"                  # 落在坏区间时替换成的版本
PYTHON_VER="3.11"
PW_BROWSERS_PATH="/usr/local/share/ms-playwright"
INSTALLER_URL="https://hermes-agent.nousresearch.com/install.sh"
UV_INSTALLER_URL="https://astral.sh/uv/install.sh"

# 基础系统包（apt）
BASE_PKGS="ca-certificates curl git xz-utils tar unzip file procps
           build-essential python3-dev libffi-dev pkg-config libssl-dev
           ripgrep ffmpeg"

# Playwright Chromium 运行库候选。跨版本包名会漂移（Ubuntu 24.04+/Debian 13 的 t64
# 转换），所以不硬编码映射表，逐个用 apt_pick 在 NAMEt64 / NAME 间择一（见该函数）。
PW_LIB_CANDIDATES="libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0
                   libcups2 libdrm2 libgbm1 libxkbcommon0 libxcomposite1
                   libxdamage1 libxfixes3 libxrandr2 libxcb1 libx11-6 libxext6
                   libexpat1 libglib2.0-0 libpango-1.0-0 libcairo2 libasound2
                   fonts-liberation"

# -------------------------------------------------------------- 运行时状态 ----

MODE="install"                     # install | check
ASSUME_YES=0
ALLOW_ARCHIVE=0
SKIP_BROWSER=0
SKIP_ENSURE=0
NODE_PREF=""
HERMES_HOME_ARG=""
LOGFILE=""

WARN_COUNT=0
FAIL_COUNT=0
REPORT=""                          # 每行 STATUS/NAME/VERSION/PATH/NOTE，制表符分隔

OS_ID=""; OS_VER=""; OS_CODENAME=""; OS_PRETTY=""
ARCH=""; NODE_ARCH=""
GLIBC_VER=""; GLIBCXX_MAX=""
IS_ROOT=0

TAB=$(printf '\t')

# ------------------------------------------------------------------ 输出 ------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    ESC=$(printf '\033')
    C_RST="${ESC}[0m"; C_DIM="${ESC}[2m"; C_B="${ESC}[1m"
    C_RED="${ESC}[31m"; C_GRN="${ESC}[32m"; C_YEL="${ESC}[33m"; C_CYA="${ESC}[36m"
else
    C_RST=""; C_DIM=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""
fi

_log_raw() {
    [ -n "$LOGFILE" ] && printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOGFILE" 2>/dev/null
    return 0
}
say()   { printf '%s\n' "$*";              _log_raw "$*"; }
info()  { printf '%s\n' "  $*";            _log_raw "INFO $*"; }
step()  { printf '\n%s%s%s\n' "$C_B$C_CYA" "$*" "$C_RST"; _log_raw "STEP $*"; }
ok()    { printf '  %s[OK]%s %s\n'   "$C_GRN" "$C_RST" "$*"; _log_raw "OK   $*"; }
warn()  { printf '  %s[!!]%s %s\n'   "$C_YEL" "$C_RST" "$*"; _log_raw "WARN $*"; WARN_COUNT=$((WARN_COUNT+1)); }
fail()  { printf '  %s[XX]%s %s\n'   "$C_RED" "$C_RST" "$*"; _log_raw "FAIL $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
dim()   { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RST"; }
die()   { printf '\n%s[XX] %s%s\n' "$C_RED$C_B" "$*" "$C_RST" >&2; _log_raw "DIE  $*"; exit 1; }

report() {  # report STATUS NAME VERSION PATH NOTE
    REPORT="${REPORT}$1${TAB}$2${TAB}$3${TAB}$4${TAB}$5
"
}

would() { dim "[check] 将执行: $*"; }

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    [ ! -t 0 ] && return 1
    printf '  %s? %s [y/N] %s' "$C_YEL" "$*" "$C_RST"
    local a
    read -r a || return 1
    case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------------ 工具 ------

have() { command -v "$1" >/dev/null 2>&1; }

# ver_ge A B  ->  真 当且仅当 A >= B
ver_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V 2>/dev/null | head -n1)" = "$2" ]
}

# 从 "v22.22.0" / "node v22.22.0" 之类里抠出纯版本号
ver_clean() {
    printf '%s' "$1" | grep -o '[0-9][0-9.]*' | head -n1
}

# apt_can_install NAME -> 该名字能被 apt 真正解析成一个可安装的包
#
# 不能用 apt-cache show 判断：Ubuntu 24.04 上 `apt-cache show libasound2` 返回成功
# （t64 转换后它是个被 Provides 的虚包，有记录），但 `apt-get install libasound2`
# 解析失败。用 -s 模拟安装才是可靠的判据，且不需要 root。
apt_can_install() {
    apt-get install -s -qq "$1" >/dev/null 2>&1
}

# apt_pick NAME -> 在 NAMEt64 和 NAME 之间挑一个真能装上的
# t64 转换后的那个才是真包，存在就优先用它。
apt_pick() {
    local n="$1"
    if apt_can_install "${n}t64"; then printf '%s' "${n}t64"; return 0; fi
    if apt_can_install "$n";      then printf '%s' "$n";      return 0; fi
    return 1
}

apt_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

apt_install() {
    [ $# -eq 0 ] && return 0
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get install -y -o Dpkg::Options::=--force-confold "$@"
}

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'USAGE'

选项:
  --check                   只检测不改动系统，输出就绪报告（无需 root）
  --yes, -y                 非交互，所有确认默认同意
  --node-version <22|24|26> 指定 Node 大版本（默认自动：24 -> 22 降级探测）
  --allow-archive-sources   授权在 Debian 11 EOL 撤源后改写 apt 源到 archive.debian.org
  --skip-browser            不预装 Playwright Chromium 及其运行库
  --skip-ensure             跳过最后调用官方 install.sh --ensure 的兜底步骤
  --hermes-home <PATH>      Hermes 数据目录（默认 ~/.hermes）
  --log <FILE>              日志文件（默认 /var/log/hermes-preflight.log）
  -h, --help                显示本帮助
USAGE
}

# ------------------------------------------------------------ 参数解析 --------

while [ $# -gt 0 ]; do
    case "$1" in
        --check)                 MODE="check" ;;
        --yes|-y)                ASSUME_YES=1 ;;
        --node-version)          NODE_PREF="${2:-}"; shift ;;
        --allow-archive-sources) ALLOW_ARCHIVE=1 ;;
        --skip-browser)          SKIP_BROWSER=1 ;;
        --skip-ensure)           SKIP_ENSURE=1 ;;
        --hermes-home)           HERMES_HOME_ARG="${2:-}"; shift ;;
        --log)                   LOGFILE="${2:-}"; shift ;;
        -h|--help)               usage; exit 0 ;;
        *) printf '未知参数: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

[ "$(id -u)" = "0" ] && IS_ROOT=1

if [ -z "$LOGFILE" ]; then
    if [ "$IS_ROOT" = 1 ] && touch /var/log/hermes-preflight.log 2>/dev/null; then
        LOGFILE=/var/log/hermes-preflight.log
    else
        LOGFILE="${TMPDIR:-/tmp}/hermes-preflight.log"
        touch "$LOGFILE" 2>/dev/null || LOGFILE=""
    fi
fi

HERMES_HOME="${HERMES_HOME_ARG:-${HERMES_HOME:-$HOME/.hermes}}"

say ""
say "${C_B}Hermes Agent 依赖预装 v${VERSION}${C_RST}"
say "${C_DIM}模式: ${MODE}   日志: ${LOGFILE:-<无>}${C_RST}"

if [ "$MODE" = "install" ] && [ "$IS_ROOT" != 1 ]; then
    die "安装模式需要 root（要装 apt 包、写 /usr/local）。请用 sudo 重跑，或加 --check 只做体检。"
fi

# ====================================================== Stage 0 环境判定 ======

step "Stage 0 -- 环境判定"

[ -r /etc/os-release ] || die "读不到 /etc/os-release，无法判断发行版。"
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-}"
OS_CODENAME="${VERSION_CODENAME:-}"
OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VER}"

info "系统: ${OS_PRETTY}  (id=${OS_ID} version=${OS_VER} codename=${OS_CODENAME:-?})"

have apt-get || die "没找到 apt-get。本脚本只覆盖 apt 系（Debian / Ubuntu）；其他发行版请手动装齐依赖后直接跑官方安装器。"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64)  NODE_ARCH="x64" ;;
    aarch64|arm64) NODE_ARCH="arm64" ;;
    armv7l)        NODE_ARCH="armv7l" ;;
    *) NODE_ARCH=""; warn "未知架构 ${ARCH}，Node 官方二进制可能没有对应包。" ;;
esac
info "架构: ${ARCH} -> node ${NODE_ARCH:-<无对应>}"

GLIBC_VER="$(ldd --version 2>/dev/null | head -n1 | grep -o '[0-9][0-9.]*$')"
[ -n "$GLIBC_VER" ] && info "glibc: ${GLIBC_VER}"

_libstdcpp="$(ldconfig -p 2>/dev/null | grep 'libstdc++\.so\.6 ' | head -n1 | awk '{print $NF}')"
if [ -n "$_libstdcpp" ] && [ -r "$_libstdcpp" ]; then
    GLIBCXX_MAX="$(strings "$_libstdcpp" 2>/dev/null | grep '^GLIBCXX_[0-9]' | sed 's/^GLIBCXX_//' | sort -V | tail -n1)"
    [ -n "$GLIBCXX_MAX" ] && info "libstdc++: 最高提供 GLIBCXX_${GLIBCXX_MAX}"
fi

grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && info "检测到 WSL2 环境。"

if [ "$OS_ID" = "debian" ] && [ "${OS_VER%%.*}" = "11" ]; then
    # bullseye 的 LTS 到 2026-08-31 为止，之后官方源撤到 archive.debian.org
    if [ "$(date +%Y%m%d)" -ge 20260831 ] 2>/dev/null; then
        warn "Debian 11 (bullseye) 的 LTS 已于 2026-08-31 结束，官方源应已撤到 archive.debian.org。"
    else
        warn "Debian 11 (bullseye) 的 LTS 将于 2026-08-31 结束，之后官方源会撤到 archive.debian.org。"
    fi
fi

report "INFO" "OS" "$OS_PRETTY" "-" "arch=${ARCH} glibc=${GLIBC_VER:-?} GLIBCXX=${GLIBCXX_MAX:-?}"
ok "环境判定完成。"

# ================================================== Stage 1 apt 源可用性 ======

step "Stage 1 -- apt 源可用性"

APT_OK=0
if [ "$MODE" = "check" ] && [ "$IS_ROOT" != 1 ]; then
    dim "非 root，跳过 apt-get update 实测（check 模式）。"
    APT_OK=1
else
    info "试跑 apt-get update ..."
    if env DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"${LOGFILE:-/dev/null}" 2>&1; then
        APT_OK=1
        ok "apt 源可用。"
    else
        fail "apt-get update 失败。"
    fi
fi

if [ "$APT_OK" != 1 ]; then
    if [ "$OS_ID" = "debian" ] && [ "${OS_VER%%.*}" = "11" ]; then
        say ""
        info "判定：Debian 11 已 EOL，官方源大概率已撤到 archive.debian.org。"
        info "拟写入 /etc/apt/sources.list:"
        dim "  deb http://archive.debian.org/debian bullseye main contrib non-free"
        dim "  deb http://archive.debian.org/debian-security bullseye-security main contrib non-free"
        dim "  另写 /etc/apt/apt.conf.d/99hermes-archive 关掉 Check-Valid-Until"

        _do_rewrite=0
        if [ "$MODE" = "check" ]; then
            would "改写 apt 源到 archive.debian.org"
            warn "check 模式不改动系统。确认无误后用 --allow-archive-sources 重跑。"
        elif [ "$ALLOW_ARCHIVE" = 1 ]; then
            _do_rewrite=1
        elif confirm "改写 apt 源到 archive.debian.org？（原文件会备份）"; then
            _do_rewrite=1
        else
            fail "apt 源不可用且未授权改写，后续包安装无法进行。"
        fi

        if [ "$_do_rewrite" = 1 ]; then
            _ts="$(date +%Y%m%d%H%M%S)"
            cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.${_ts}" 2>/dev/null \
                && info "已备份 -> /etc/apt/sources.list.bak.${_ts}"
            {
                echo "deb http://archive.debian.org/debian bullseye main contrib non-free"
                echo "deb http://archive.debian.org/debian-security bullseye-security main contrib non-free"
            } >/etc/apt/sources.list
            printf 'Acquire::Check-Valid-Until "false";\n' >/etc/apt/apt.conf.d/99hermes-archive

            # sources.list.d 里指向已撤源的条目一并注释掉
            for f in /etc/apt/sources.list.d/*.list; do
                [ -e "$f" ] || continue
                if grep -qE '^[[:space:]]*deb .*(deb\.debian\.org|security\.debian\.org)' "$f" 2>/dev/null; then
                    cp -a "$f" "${f}.bak.${_ts}" 2>/dev/null
                    sed -i -E 's|^([[:space:]]*deb .*(deb\.debian\.org\|security\.debian\.org).*)$|# [hermes-preflight] \1|' "$f"
                    info "已注释失效条目: $f （备份 ${f}.bak.${_ts}）"
                fi
            done

            if env DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"${LOGFILE:-/dev/null}" 2>&1; then
                APT_OK=1
                FAIL_COUNT=$((FAIL_COUNT-1))   # 上面那次 fail 已被修复
                ok "改写后 apt 源可用。"
            else
                fail "改写后 apt-get update 仍失败，请查看 ${LOGFILE:-日志}。"
            fi
        fi
    else
        warn "apt 源不可用，且不是 Debian 11 EOL 场景。请自行检查网络 / 源配置 / 代理。"
    fi
fi

if [ "$APT_OK" = 1 ]; then
    report "OK" "apt-sources" "-" "/etc/apt/sources.list" "可用"
else
    report "FAIL" "apt-sources" "-" "/etc/apt/sources.list" "apt-get update 失败"
    [ "$MODE" = "install" ] && die "apt 源不可用，无法继续安装。"
fi

# ================================================== Stage 2 基础系统包 ========

step "Stage 2 -- 基础系统包"

_want=""; _missing=""
for p in $BASE_PKGS; do
    # 先解析真实包名再判断是否已装 —— 装着的可能是 t64 变体
    if real="$(apt_pick "$p")"; then
        apt_installed "$real" && continue
        _want="$_want $real"
        _missing="$_missing $real"
    else
        warn "仓库里没有可安装的 ${p}（也没有 ${p}t64），跳过。"
    fi
done

if [ -z "$_missing" ]; then
    ok "基础包已齐全。"
else
    info "缺少:${_missing}"
    if [ "$MODE" = "check" ]; then
        would "apt-get install -y${_missing}"
    else
        # shellcheck disable=SC2086
        if apt_install $_want >>"${LOGFILE:-/dev/null}" 2>&1; then
            ok "基础包安装完成。"
        else
            fail "基础包安装失败，详见 ${LOGFILE:-日志}。"
        fi
    fi
fi

for p in git curl rg ffmpeg gcc; do
    if have "$p"; then
        case "$p" in
            git)    v="$(git --version 2>/dev/null | head -n1)" ;;
            curl)   v="$(curl --version 2>/dev/null | head -n1 | cut -d' ' -f1-2)" ;;
            rg)     v="ripgrep $(rg --version 2>/dev/null | head -n1 | awk '{print $2}')" ;;
            ffmpeg) v="$(ffmpeg -version 2>/dev/null | head -n1 | cut -d' ' -f1-3)" ;;
            gcc)    v="$(gcc --version 2>/dev/null | head -n1 | cut -c1-24)" ;;
            *)      v="-" ;;
        esac
        report "OK" "$p" "$v" "$(command -v "$p")" "-"
    else
        if [ "$MODE" = "check" ]; then
            report "MISSING" "$p" "-" "-" "未安装"
        else
            report "FAIL" "$p" "-" "-" "未安装"
        fi
    fi
done

# ====================================================== Stage 3 Node.js =======

step "Stage 3 -- Node.js（按实际可执行性验证，而非只看版本号）"

NODE_READY=0
if have node && have npm; then
    _nv="$(ver_clean "$(node -v 2>/dev/null)")"
    if [ -n "$_nv" ] && ver_ge "$_nv" "$NODE_MIN" && node -e 'process.exit(0)' >/dev/null 2>&1; then
        NODE_READY=1
        ok "已有可用 Node v${_nv}（>= ${NODE_MIN}），跳过安装。"
        report "OK" "node" "v${_nv}" "$(command -v node)" "满足下限 ${NODE_MIN}"
    else
        warn "已有 Node（${_nv:-未知}）不满足下限 ${NODE_MIN} 或无法执行，将安装新版本。"
    fi
else
    info "未检测到 node/npm。"
fi

if [ "$NODE_READY" != 1 ]; then
    if [ -z "$NODE_ARCH" ]; then
        fail "架构 ${ARCH} 没有对应的 Node 官方二进制，请改用发行版自带的 nodejs 包。"
        report "FAIL" "node" "-" "-" "无对应架构二进制"
    elif [ "$MODE" = "check" ]; then
        would "下载并安装 Node（候选大版本: ${NODE_PREF:-$NODE_CANDIDATES}）到 /usr/local"
        report "MISSING" "node" "-" "-" "需安装，下限 ${NODE_MIN}"
    else
        _cands="${NODE_PREF:-$NODE_CANDIDATES}"
        _tmp="$(mktemp -d)"
        trap 'rm -rf "$_tmp"' EXIT

        for V in $_cands; do
            info "尝试 Node ${V}.x ..."
            _idx="https://nodejs.org/dist/latest-v${V}.x/"
            _file="$(curl -fsSL --max-time 60 "$_idx" 2>/dev/null \
                     | grep -o "node-v[0-9.]\{1,\}-linux-${NODE_ARCH}\.tar\.xz" | head -n1)"
            if [ -z "$_file" ]; then
                warn "取不到 Node ${V}.x 的文件列表（${_idx}），跳过。"
                continue
            fi
            info "  找到 ${_file}，下载中 ..."
            if ! curl -fsSL --max-time 900 -o "${_tmp}/${_file}" "${_idx}${_file}"; then
                warn "  下载失败，跳过 Node ${V}.x。"
                continue
            fi
            rm -rf "${_tmp}/x"; mkdir -p "${_tmp}/x"
            if ! tar -xJf "${_tmp}/${_file}" -C "${_tmp}/x" --strip-components=1 2>>"${LOGFILE:-/dev/null}"; then
                warn "  解压失败，跳过 Node ${V}.x。"
                continue
            fi

            # 关键一步：实际执行，而不是相信版本号。
            # glibc / GLIBCXX 不够会在这里暴露，而不是等到正式安装时才炸。
            if _out="$("${_tmp}/x/bin/node" -v 2>&1)" && printf '%s' "$_out" | grep -q '^v[0-9]'; then
                ok "  Node ${_out} 实测可运行，安装到 /usr/local ..."
            else
                warn "  Node ${V}.x 在本机跑不起来: $(printf '%s' "$_out" | head -n1)"
                continue
            fi

            if tar -xJf "${_tmp}/${_file}" -C /usr/local --strip-components=1 \
                    --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md \
                    2>>"${LOGFILE:-/dev/null}"; then
                hash -r 2>/dev/null || true
                NODE_READY=1
                break
            else
                warn "  安装到 /usr/local 失败。"
            fi
        done
        rm -rf "$_tmp"; trap - EXIT

        if [ "$NODE_READY" = 1 ]; then
            _nv="$(ver_clean "$(node -v 2>/dev/null)")"
            ok "Node v${_nv} 就绪。"
            report "OK" "node" "v${_nv}" "$(command -v node)" "新装"
        else
            fail "所有候选 Node 版本都装不上，请检查网络，或用 --node-version 指定其他大版本。"
            report "FAIL" "node" "-" "-" "安装失败"
        fi
    fi
fi

# npm 版本黑名单：install.sh 拒绝 [11.10.0, 11.17.0)
if have npm; then
    _npmv="$(ver_clean "$(npm -v 2>/dev/null)")"
    if [ -n "$_npmv" ] && ver_ge "$_npmv" "$NPM_BAD_LO" && ! ver_ge "$_npmv" "$NPM_BAD_HI"; then
        warn "npm ${_npmv} 落在安装器拒绝的区间 [${NPM_BAD_LO}, ${NPM_BAD_HI})。"
        if [ "$MODE" = "check" ]; then
            would "npm install -g npm@${NPM_SAFE}"
            report "WARN" "npm" "$_npmv" "$(command -v npm)" "在黑名单区间，需换 ${NPM_SAFE}"
        elif npm install -g "npm@${NPM_SAFE}" >>"${LOGFILE:-/dev/null}" 2>&1; then
            hash -r 2>/dev/null || true
            _npmv="$(ver_clean "$(npm -v 2>/dev/null)")"
            ok "npm 已切到 ${_npmv}。"
            report "OK" "npm" "$_npmv" "$(command -v npm)" "已避开黑名单区间"
        else
            fail "npm 降级失败。"
            report "FAIL" "npm" "$_npmv" "$(command -v npm)" "降级失败"
        fi
    else
        ok "npm ${_npmv} 不在黑名单区间。"
        report "OK" "npm" "$_npmv" "$(command -v npm)" "-"
    fi
elif [ "$MODE" = "check" ]; then
    report "MISSING" "npm" "-" "-" "随 node 一并安装"
fi

# =================================================== Stage 4 uv + Python ======

step "Stage 4 -- uv + Python ${PYTHON_VER}"

UV_PY_DIR="$HOME/.local/share/uv/python"
# root 下与 install.sh 的 FHS 布局保持一致，否则正式安装时它会再下一份
[ "$IS_ROOT" = 1 ] && UV_PY_DIR="/usr/local/share/uv/python"

if have uv; then
    _uvv="$(uv --version 2>/dev/null | awk '{print $2}')"
    ok "已有 uv ${_uvv}。"
    report "OK" "uv" "$_uvv" "$(command -v uv)" "-"
elif [ "$MODE" = "check" ]; then
    would "curl -fsSL ${UV_INSTALLER_URL} | UV_INSTALL_DIR=/usr/local/bin sh"
    report "MISSING" "uv" "-" "-" "需安装"
else
    info "安装 uv 到 /usr/local/bin ..."
    if curl -fsSL --max-time 300 "$UV_INSTALLER_URL" \
         | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh >>"${LOGFILE:-/dev/null}" 2>&1; then
        hash -r 2>/dev/null || true
        if have uv; then
            _uvv="$(uv --version 2>/dev/null | awk '{print $2}')"
            ok "uv ${_uvv} 安装完成。"
            report "OK" "uv" "$_uvv" "$(command -v uv)" "新装"
        else
            fail "uv 安装脚本跑完但找不到 uv 命令。"
            report "FAIL" "uv" "-" "-" "安装后不可见"
        fi
    else
        fail "uv 安装失败。"
        report "FAIL" "uv" "-" "-" "安装失败"
    fi
fi

_seed_python() {   # _seed_python <user|""> <python_install_dir>
    if [ -n "$1" ]; then
        sudo -u "$1" env UV_PYTHON_INSTALL_DIR="$2" UV_NO_CONFIG=1 \
             uv python install "$PYTHON_VER" >>"${LOGFILE:-/dev/null}" 2>&1
    else
        env UV_PYTHON_INSTALL_DIR="$2" UV_NO_CONFIG=1 \
             uv python install "$PYTHON_VER" >>"${LOGFILE:-/dev/null}" 2>&1
    fi
}

if have uv; then
    if env UV_PYTHON_INSTALL_DIR="$UV_PY_DIR" uv python list --only-installed 2>/dev/null \
         | grep -q "cpython-${PYTHON_VER}"; then
        ok "Python ${PYTHON_VER} 已就位（${UV_PY_DIR}）。"
        report "OK" "python${PYTHON_VER}" "installed" "$UV_PY_DIR" "uv 托管"
    elif [ "$MODE" = "check" ]; then
        would "UV_PYTHON_INSTALL_DIR=${UV_PY_DIR} uv python install ${PYTHON_VER}"
        report "MISSING" "python${PYTHON_VER}" "-" "$UV_PY_DIR" "需安装"
    elif _seed_python "" "$UV_PY_DIR"; then
        ok "Python ${PYTHON_VER} 就绪（${UV_PY_DIR}）。"
        report "OK" "python${PYTHON_VER}" "installed" "$UV_PY_DIR" "uv 托管"
    else
        fail "Python ${PYTHON_VER} 安装失败，详见 ${LOGFILE:-日志}。"
        report "FAIL" "python${PYTHON_VER}" "-" "$UV_PY_DIR" "安装失败"
    fi

    # sudo 进来的话，普通用户身份跑 install.sh 时 uv 会去找 ~/.local/share/uv/python，
    # 顺手也给那个用户预置一份，省得正式安装时重下一遍。
    if [ "$MODE" = "install" ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        _uhome="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
        if [ -n "$_uhome" ]; then
            _udir="${_uhome}/.local/share/uv/python"
            if sudo -u "$SUDO_USER" env UV_PYTHON_INSTALL_DIR="$_udir" uv python list --only-installed 2>/dev/null \
                 | grep -q "cpython-${PYTHON_VER}"; then
                dim "用户 ${SUDO_USER} 的 Python ${PYTHON_VER} 已就位。"
            elif _seed_python "$SUDO_USER" "$_udir"; then
                ok "已为用户 ${SUDO_USER} 预置 Python ${PYTHON_VER}。"
            else
                warn "为用户 ${SUDO_USER} 预置 Python 失败（不致命，正式安装时会自行下载）。"
            fi
        fi
    fi
fi

# ============================================ Stage 5 Playwright Chromium =====

step "Stage 5 -- Playwright Chromium 运行库与浏览器"

_chrome=""
if [ "$SKIP_BROWSER" = 1 ]; then
    dim "已指定 --skip-browser，跳过。"
    report "SKIP" "chromium" "-" "-" "--skip-browser"
else
    # --- 5a. 运行库 ---
    _pwwant=""; _pwmiss=""
    for p in $PW_LIB_CANDIDATES; do
        if real="$(apt_pick "$p")"; then
            apt_installed "$real" && continue
            _pwwant="$_pwwant $real"; _pwmiss="$_pwmiss $real"
        else
            warn "仓库里没有可安装的 ${p}（也没有 ${p}t64），跳过。"
        fi
    done

    if [ -z "$_pwmiss" ]; then
        ok "Chromium 运行库已齐全。"
    else
        info "缺少运行库:${_pwmiss}"
        if [ "$MODE" = "check" ]; then
            would "apt-get install -y${_pwmiss}"
        else
            # shellcheck disable=SC2086
            if apt_install $_pwwant >>"${LOGFILE:-/dev/null}" 2>&1; then
                ok "Chromium 运行库安装完成。"
            else
                fail "Chromium 运行库安装失败，详见 ${LOGFILE:-日志}。"
            fi
        fi
    fi

    # --- 5b. 浏览器本体 ---
    # 注意不加 --with-deps —— 那正是 bullseye 上报 "only Ubuntu is supported"
    # 或漏装库的地方。运行库我们上面已经自己按包名装过了。
    if [ -d "$PW_BROWSERS_PATH" ]; then
        _chrome="$(find "$PW_BROWSERS_PATH" -type f -name chrome 2>/dev/null | head -n1)"
    fi

    if [ -n "$_chrome" ]; then
        ok "Chromium 已存在: ${_chrome}"
    elif [ "$MODE" = "check" ]; then
        would "PLAYWRIGHT_BROWSERS_PATH=${PW_BROWSERS_PATH} npx -y playwright install chromium"
        report "MISSING" "chromium" "-" "$PW_BROWSERS_PATH" "需安装"
    elif ! have npx; then
        fail "没有 npx（Node 未就绪），无法安装 Chromium。"
        report "FAIL" "chromium" "-" "-" "缺 npx"
    else
        info "下载 Chromium 到 ${PW_BROWSERS_PATH}（不带 --with-deps）..."
        mkdir -p "$PW_BROWSERS_PATH"
        if env PLAYWRIGHT_BROWSERS_PATH="$PW_BROWSERS_PATH" \
               timeout 900 npx -y playwright install chromium >>"${LOGFILE:-/dev/null}" 2>&1; then
            _chrome="$(find "$PW_BROWSERS_PATH" -type f -name chrome 2>/dev/null | head -n1)"
            ok "Chromium 安装完成。"
        else
            fail "Chromium 安装失败，详见 ${LOGFILE:-日志}。"
        fi
    fi

    # --- 5c. 实测：ldd 抓缺失的 .so ---
    if [ -n "$_chrome" ]; then
        _miss_so="$(ldd "$_chrome" 2>/dev/null | grep 'not found' | awk '{print $1}' | sort -u)"
        if [ -z "$_miss_so" ]; then
            ok "ldd 校验通过，Chromium 依赖齐全。"
            report "OK" "chromium" "installed" "$_chrome" "ldd 无缺失"
        else
            fail "Chromium 仍缺以下动态库："
            for so in $_miss_so; do
                _hint=""
                if have apt-file; then
                    _hint="$(apt-file search -x "/${so}$" 2>/dev/null | head -n1 | cut -d: -f1)"
                fi
                if [ -n "$_hint" ]; then
                    printf '      %s   -> apt-get install %s\n' "$so" "$_hint"
                else
                    printf '      %s\n' "$so"
                fi
            done
            have apt-file || dim "提示: apt-get install apt-file && apt-file update 后重跑，可自动给出包名建议。"
            report "FAIL" "chromium" "installed" "$_chrome" "缺库: $(printf '%s' "$_miss_so" | tr '\n' ' ')"
        fi
    fi

    # --- 5d. 让后续所有会话都找得到这份系统级浏览器目录 ---
    if [ "$MODE" = "install" ] && [ "$IS_ROOT" = 1 ] && [ -d "$PW_BROWSERS_PATH" ]; then
        if [ ! -f /etc/profile.d/hermes-playwright.sh ]; then
            printf 'export PLAYWRIGHT_BROWSERS_PATH=%s\n' "$PW_BROWSERS_PATH" \
                >/etc/profile.d/hermes-playwright.sh
            chmod 0644 /etc/profile.d/hermes-playwright.sh
            info "已写 /etc/profile.d/hermes-playwright.sh（新登录会话生效）。"
        fi
        chmod -R a+rX "$PW_BROWSERS_PATH" 2>/dev/null || true
    fi
fi

# ============================================= Stage 6 官方 --ensure 兜底 =====

step "Stage 6 -- 官方 install.sh --ensure 兜底"

_ensure_list="node,browser,ripgrep,ffmpeg"
[ "$SKIP_BROWSER" = 1 ] && _ensure_list="node,ripgrep,ffmpeg"

if [ "$SKIP_ENSURE" = 1 ]; then
    dim "已指定 --skip-ensure，跳过。"
elif [ "$MODE" = "check" ]; then
    would "curl -fsSL ${INSTALLER_URL} | bash -s -- --ensure ${_ensure_list}"
elif [ "$FAIL_COUNT" -gt 0 ]; then
    warn "前面有失败项，跳过 --ensure 兜底（先把上面的问题修好）。"
else
    info "跑官方依赖通道查漏补缺（预期全部命中「已存在」，应该很快）..."
    if curl -fsSL --max-time 120 "$INSTALLER_URL" -o /tmp/hermes-install.sh 2>>"${LOGFILE:-/dev/null}"; then
        if env PLAYWRIGHT_BROWSERS_PATH="$PW_BROWSERS_PATH" HERMES_HOME="$HERMES_HOME" \
               timeout 1200 bash /tmp/hermes-install.sh --ensure "$_ensure_list" \
               >>"${LOGFILE:-/dev/null}" 2>&1; then
            ok "官方 --ensure 通过。"
            report "OK" "install.sh --ensure" "$_ensure_list" "-" "官方依赖通道通过"
        else
            warn "官方 --ensure 返回非零（不一定致命，详见 ${LOGFILE:-日志}）。"
            report "WARN" "install.sh --ensure" "$_ensure_list" "-" "返回非零"
        fi
        rm -f /tmp/hermes-install.sh
    else
        warn "下载 ${INSTALLER_URL} 失败，跳过兜底。"
        report "WARN" "install.sh --ensure" "-" "-" "下载失败"
    fi
fi

# ==================================================== 汇总报告 ================

step "就绪报告"

printf '\n'
printf '%s' "$REPORT" | awk -F'\t' -v g="$C_GRN" -v y="$C_YEL" -v r="$C_RED" -v d="$C_DIM" -v n="$C_RST" '
BEGIN {
    printf "  %-8s %-20s %-26s %s\n", "STATUS", "COMPONENT", "VERSION", "PATH / NOTE"
    printf "  %s%s%s\n", d, "-----------------------------------------------------------------------------", n
}
NF >= 4 {
    c = d
    if ($1 == "OK")   c = g
    if ($1 == "WARN" || $1 == "MISSING") c = y
    if ($1 == "FAIL") c = r
    path = $4
    if (length(path) > 34) path = "..." substr(path, length(path) - 30)
    note = (NF >= 5 && $5 != "-") ? ("  (" $5 ")") : ""
    printf "  %s%-8s%s %-20s %-26s %s%s\n", c, $1, n, $2, $3, path, note
}'
printf '\n'

if [ "$MODE" = "check" ]; then
    say "  ${C_DIM}以上为体检结果，未对系统做任何改动。${C_RST}"
    say "  执行安装:  ${C_B}sudo bash $0 --yes${C_RST}"
elif [ "$FAIL_COUNT" -gt 0 ]; then
    say "  ${C_RED}${C_B}有 ${FAIL_COUNT} 项失败${C_RST}，修好后重跑本脚本（幂等，已完成的会跳过）。"
    say "  日志: ${LOGFILE:-<无>}"
else
    say "  ${C_GRN}${C_B}依赖全部就绪。${C_RST}现在可以正式安装 Hermes Agent:"
    say ""
    say "    ${C_B}curl -fsSL ${INSTALLER_URL} | bash${C_RST}"
    say ""
    say "  安装完成后:"
    say "    source ~/.bashrc && hermes doctor"
    [ "$WARN_COUNT" -gt 0 ] && say "  ${C_YEL}（有 ${WARN_COUNT} 条警告，见上方与日志）${C_RST}"
fi
say ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
elif [ "$WARN_COUNT" -gt 0 ]; then
    exit 2
else
    exit 0
fi
