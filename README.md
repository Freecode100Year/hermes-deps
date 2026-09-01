# Hermes Agent 依赖预装（Debian 11 / 12 / 13、Ubuntu）

在正式跑官方安装器之前，先把 Hermes Agent 需要的全部依赖装齐并**实测验证**，
让正式安装时每个检测点都命中「已存在 → 跳过」，避免长链条网络安装半路失败。

**依赖看板** → <https://claude.ai/code/artifact/5e76af9d-cec8-4648-b243-dd52cc04d356>

每天由定时任务核对一次上游版本后重新发布：Node 各版本线、uv、Playwright、
官方安装器的指纹与关键常量。页面源码就是本仓库的 `dashboard.html`。

> 该看板是一个 Claude Artifact，默认私有 —— 只有页面所有者从分享菜单公开后，
> 上面这个链接对其他人才可访问。

```
hermes-deps/
├── hermes-preflight.sh   # 主脚本，单文件、幂等、可重复执行
├── dashboard.html        # 依赖看板页面源码，由定时任务每日更新后重新发布
└── README.md
```

## 为什么这样做有效

官方 `install.sh` 的每个依赖都是**先 `command -v` 探测、存在就跳过**（Node 额外校验，而且
不是单一下限：三段式 `22.22+ / 24.11+ / 26+`，`nanoid` 6 排斥 23、25，`@babel/*` 8.x 要求
`^22.18.0 || >=24.11.0`）。所以「预装」不是绕过安装器，而是它本来就支持的路径。

它还自带 `--ensure node,browser,ripgrep,ffmpeg` —— 只装依赖、不 clone repo、不建 venv。
本脚本在最后一步会调用它作为兜底查漏。

## 用法

```bash
# 1. 体检：只检测，不改动系统（不需要 root）
bash hermes-preflight.sh --check

# 2. 装齐依赖
sudo bash hermes-preflight.sh

# 3. 非交互（CI / 批量）
sudo bash hermes-preflight.sh --yes --allow-archive-sources

# 4. 依赖就绪后，正式安装 Hermes
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
source ~/.bashrc && hermes doctor
```

从 Windows 传到 Linux：

```powershell
scp C:\Users\sj929\hermes-deps\hermes-preflight.sh user@host:~/
```

传过去后如果报 `bad interpreter: ^M`，说明换行被转成了 CRLF，执行 `sed -i 's/\r$//' hermes-preflight.sh`。

### 选项

| 选项 | 说明 |
|---|---|
| `--check` | 只检测不改动系统，输出就绪报告 |
| `--yes` / `-y` | 非交互，所有确认默认同意 |
| `--node-version <22\|24\|26>` | 指定 Node 大版本（默认自动 24 → 22 降级探测） |
| `--allow-archive-sources` | 授权在 Debian 11 EOL 撤源后改写 apt 源到 `archive.debian.org` |
| `--skip-browser` | 不预装 Playwright Chromium 及其运行库 |
| `--skip-ensure` | 跳过最后调用官方 `--ensure` 的兜底步骤 |
| `--hermes-home <PATH>` | Hermes 数据目录（默认 `~/.hermes`） |
| `--log <FILE>` | 日志文件（默认 `/var/log/hermes-preflight.log`） |

退出码：`0` 全部就绪 / `1` 致命失败 / `2` 完成但有警告。

## 六个阶段

| Stage | 做什么 |
|---|---|
| 0 | 读 `/etc/os-release`，确认 apt 系；记录架构、glibc、libstdc++ 最高 `GLIBCXX` |
| 1 | 试跑 `apt-get update`；Debian 11 撤源场景下（经授权）改写到 `archive.debian.org`，原文件备份 |
| 2 | 基础包：`ca-certificates curl git xz-utils tar unzip file procps build-essential python3-dev libffi-dev pkg-config libssl-dev ripgrep ffmpeg libatomic1` |
| 3 | Node.js：**下载后实际执行 `node -v` 验证**，24 → 22 降级；npm 落在 `[11.10.0, 11.17.0)` 黑名单则换成 11.9.2 |
| 4 | `uv` 装到 `/usr/local/bin`，`uv python install 3.11` 预置到与 install.sh 一致的路径 |
| 5 | Chromium 运行库（跨版本 `t64` 包名自动择一）+ `npx playwright install chromium`（**不带** `--with-deps`）+ `ldd` 实测校验 |
| 6 | 调官方 `install.sh --ensure` 兜底，然后打印就绪报告 |

## Debian 11 上专门处理的四个坑

**1. bullseye 的 LTS 在 2026-08-31 到期，之后官方源撤走**
`apt-get update` 会直接失败。脚本检测到后提示改写 `sources.list` 到 `archive.debian.org`，
并写 `Acquire::Check-Valid-Until "false"`；原文件带时间戳备份，`sources.list.d` 里指向
已撤源的条目也一并注释（同样备份）。需要 `--allow-archive-sources` 或交互确认才动手。

**2. Node 二进制的 libc 兼容性（实测，不靠猜）**
Node 官方 Linux x64/arm64 二进制的 tier-1 下限是 glibc ≥ 2.28、libstdc++ ≥ 6.0.25
（`GLIBCXX_3.4.25`）。bullseye 是 glibc 2.31 + `GLIBCXX_3.4.28`，**满足要求，Node 26
本身是能跑的**。脚本仍然下载解包后先执行一次 `./bin/node -v` 再决定装不装，跑不起来就
自动降到下一个大版本 —— 这是零成本的保险，同时也覆盖了更老的衍生发行版。Hermes 的引擎
要求是三段式 `22.22+ / 24.11+ / 26+`（`nanoid` 6 排斥 23、25，`@babel/*` 8.x 要求
`^22.18.0 || >=24.11.0`），脚本只装 22.x / 24.x / 26.x 各自最新版，落点都在这些区间内；
装好后官方安装器探测到就不会再拉别的版本。若机器上已有系统 Node 恰好卡在空档（23.x、
25.x 或 24.0–24.10），脚本按同样的三段式校验，不会误判为已就绪。

**3. Playwright 不再支持 bullseye**
`playwright install --with-deps` 在 bullseye 上会报 "only Ubuntu is supported" 或漏装库。
脚本改为自己按包名装齐运行库，只跑不带 `--with-deps` 的 `npx playwright install chromium`，
最后用 `ldd chrome | grep "not found"` 实测校验，缺什么直接报出来。

**4. npm 版本黑名单**
官方安装器拒绝 npm `11.10.0`–`11.16.x`（`.npmrc` 兼容问题），脚本检测到会自动换成 11.9.2。

另外，Ubuntu 24.04+ / Debian 13 的 time_t 转换把 `libasound2` 改名成了 `libasound2t64`
（`libatk1.0-0`、`libcups2`、`libatspi2.0-0`、`libglib2.0-0` 同理）。脚本不硬编码映射表，
对每个候选名用 `apt-get install -s` 模拟安装来探测，t64 变体优先。**不能用 `apt-cache show`**：Ubuntu 24.04 上它对 `libasound2` 返回成功（被 Provides 的虚包），但实际装不上。

## 排查

| 现象 | 处理 |
|---|---|
| `apt-get update` 失败 | Debian 11 加 `--allow-archive-sources`；其他情况查网络/代理/源配置 |
| Node 全部候选都装不上 | 看日志里 `node -v` 的报错；若是 GLIBC/GLIBCXX 不足，用 `--node-version 22` |
| Chromium `ldd` 报缺库 | 按脚本输出的 `.so` 名装包；先 `apt-get install apt-file && apt-file update` 可让脚本自动给包名建议 |
| `hermes: command not found` | `source ~/.bashrc`，确认 PATH 含 `~/.local/bin` |
| 装完仍有异常 | `hermes doctor`、`hermes config check` |

## 验证

```bash
# 干净系统上应报大量 MISSING，且不产生任何改动
bash hermes-preflight.sh --check

# 全绿收尾
sudo bash hermes-preflight.sh --yes

# 再跑一次验证幂等：全部命中「已存在」，无重复下载
sudo bash hermes-preflight.sh --yes

# 逐项手工确认
node -v                                   # >= 22.22.0
npm -v                                    # 不在 11.10 - 11.16
uv python list --only-installed | grep 3.11
rg --version; ffmpeg -version | head -1; git --version
ldd "$(find /usr/local/share/ms-playwright -name chrome | head -1)" | grep 'not found'   # 应无输出
```

容器里快速验证：

```bash
docker run --rm -it debian:11-slim bash -c \
  'apt-get update -qq 2>/dev/null; apt-get install -y -qq curl >/dev/null; bash' 
# 然后把脚本 cat 进去跑
```

## 范围

**覆盖**：Debian 11/12/13、Ubuntu（apt 系），CLI / 服务端用法。

**不覆盖**：dnf / pacman / zypper / apk（Alpine 是 musl，Node 官方二进制和 uv 的
python-build-standalone 都跑不了，需要另一套思路）；Electron 桌面版的 GTK/X11/libsecret
依赖；Hermes 本体安装、venv 创建、LLM provider 配置 —— 那些交给官方 `install.sh`。
