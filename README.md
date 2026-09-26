# 🚀 WorkBuddy 一键部署与反代增强版 (WorkBuddy2API + Manager)

> **一行命令在 Linux 服务器上快速部署 WorkBuddy 账号池网关与管理面板，完美兼顾 Nginx / 科技Lion (kejilion) 工具箱与原生 Caddy，零端口冲突，开箱即用。**

---

## 💡 为什么需要这个增强版本？

原版部署脚本在标准空机器上表现良好，但在真实运维环境中，绝大多数服务器已安装了 **Nginx / 科技Lion 工具箱 (kejilion.sh) / 宝塔 / 1Panel** 等建站环境，此时 80 和 443 端口已被独占。原脚本强行安装 Caddy 会直接引发严重的**端口冲突与服务崩溃**。

本**升级增强版**由实战场景驱动，重点攻克了**端口兼容、AI 流式输出（SSE）卡顿、API Key 自动化签发**等核心痛点：

### 🌟 核心升级亮点

| 痛点场景 | 原版表现 | 升级增强版表现 |
| :--- | :--- | :--- |
| **已有 Nginx / 科技Lion 80/443 占用** | 强行装 Caddy 导致端口冲突、服务报错崩溃 | **智能感知环境**：自动识别原生 Nginx 及 Docker 容器版 Nginx，跳过 Caddy，直接生成反代配置并热重载，**零冲突无缝共存** |
| **AI 逐字打字机（SSE）体验** | 反代缓冲未完全禁用，可能导致打字卡顿、突发吐字 | **SSE 深度强化**：禁用一切下游代理缓冲，开启 `X-Accel-Buffering no` 与 `chunked_transfer_encoding`，保障打字机流畅如丝 |
| **大模型深度思考长连接** | 默认超时较短，复杂长推理（如 o1 / r1）易 504 中断 | **600 秒长连接超时保障**，大文本生成与长时间任务稳定不掉线 |
| **外网 API 密钥自动签发** | 仅单次请求，小内存机器启动延迟易导致建 key 失败 | **增加 3 次智能退避重试**，确保护航自动生成 `MANAGER_API_KEY` 并写入凭据 |
| **宿主端口安全性** | 容易误暴露至公网 | 网关 (`7863`) 与面板 (`7864`) **强制仅绑定 `127.0.0.1`**，彻底隔离公网扫描风险 |

---

## 🏗️ 架构拓扑与运行流程

```mermaid
flowchart TD
    subgraph Client ["客户端调用层"]
        A1[Cherry Studio / NextChat / 各类 AI 客户端]
        A2[管理员浏览器访问 Web 控制台]
    end

    subgraph ReverseProxy ["反向代理层 (公网入口)"]
        B1["科技Lion / 系统 Nginx (80/443)"]
        B2["原生 Caddy 自动 HTTPS (纯净机模式)"]
    end

    subgraph Internal ["服务器本地 (127.0.0.1 安全隔离)"]
        C1["管理面板: workbuddy-manager (:7864)"]
        C2["上游网关: workbuddy2api (:7863)"]
    end

    subgraph Upstream ["官方服务"]
        D1[WorkBuddy 官方 API / 账号池调度]
    end

    A1 -->|HTTPS 带着 API Key 请求 /v1| B1
    A2 -->|HTTPS 访问管理界面| B1
    A1 -.->|纯净机模式| B2
    A2 -.->|纯净机模式| B2

    B1 -->|本地流式反代 / 关闭缓冲 / 600s 超时| C1
    B2 -->|本地反代| C1
    C1 <-->|Docker 内部网桥 wbnet| C2
    C2 -->|轮换各账号 Token| D1
```

---

## ⚡ 极速开始：一条命令搞定

### 1. 全自动推荐部署（适合已有域名）
如果你的域名解析已指向服务器公网 IP：
```bash
curl -fsSL https://raw.githubusercontent.com/macsur/WorkBuddy/main/workbuddy-deploy.sh | sudo bash -s -- --domain workbuddy.example.com --auto
```

### 2. 交互式向导部署（推荐新手）
直接运行，脚本会友好提示输入域名、管理员密码等；直接回车即用自动计算的安全默认值：
```bash
bash workbuddy-deploy.sh
```

### 3. 纯本地私密部署（不分配外网域名）
如果不开放公网域名，仅通过内网或 SSH 隧道管理：
```bash
bash workbuddy-deploy.sh --auto
```

---

## 🖥️ 命令行参数与环境变量

脚本支持完整的无交互自动化调用，所有参数均可通过命令行或环境变量传入：

### 命令行选项
| 参数 | 简写 | 默认值 | 作用说明 |
| :--- | :---: | :---: | :--- |
| `--domain <域名>` | `-d` | *留空* | 面板与对外访问的主域名（如 `workbuddy.example.com`） |
| `--api-domain <域名>` | | *与面板同域* | 独立 API 域名（仅暴露 `/v1/*` 路径，隐藏管理控制台） |
| `--password <密码>` | `-p` | *随机强密码* | 面板管理员 `admin` 的初始密码（≥8 位，禁双引号和反斜杠） |
| `--auto` | `-a` | *交互* | 全自动非交互模式，跳过所有提问直接开跑 |
| `--base-dir <目录>` | | `/opt/wb2api` | 安装根目录与配置持久化存储位置 |
| `--help` | `-h` | | 显示命令行帮助信息 |

### 可覆盖的环境变量
- `WB2API_PORT`：宿主机侧网关端口（默认 `7863`，仅绑 `127.0.0.1`）
- `MANAGER_PORT`：宿主机侧面板端口（默认 `7864`，仅绑 `127.0.0.1`）
- `SYNC_CODE`：重跑时是否拉取远端仓库最新代码（默认 `1`；若有本地代码魔改请设为 `0`）
- `WB2API_IMAGE` / `MANAGER_IMAGE`：自定义网关与面板镜像

---

## 🦁 深度适配：与科技Lion工具箱（kejilion.sh）无缝协同

如果你已经在 VPS 上使用了 **科技Lion (kejilion.sh)**：
1. **自动规避冲突**：脚本在预检阶段会自动检测科技Lion的 Docker Nginx 容器（`nginx:alpine`）及 `/home/web/conf.d` 路径。
2. **无需额外安装反代**：脚本不会再去下载或安装 Caddy，直接生成优化版的 Nginx 配置并热重载。
3. **SSL 证书一键申请**：
   - 方案 A：直接运行脚本带上 `--domain`，脚本会自动通过配置加载证书；
   - 方案 B：随时打开科技Lion菜单 `bash <(curl -sL kejilion.sh)` -> 进入 **【建站】** -> **【站点反向代理】**，目标填写 `http://127.0.0.1:7864`，并一键开启 HTTPS。

---

---

## ⏰ 定时积分任务自动化体系 (6 大任务独立排程)

网关深度集成了全自动积分与账号保活生态，支持 **6 类任务独立排程、独立开关、确定性抖动与手动异步补跑**：

```mermaid
gantt
    title WorkBuddy 自动化任务每日排程时刻表 (默认整点分布)
    dateFormat  HH:mm
    axisFormat  %H:%M
    section 夜间/清晨
    夜猫子任务 (cat - 补黑猫)       :01:00, 10m
    section 上午
    每日签到 + 余额自检 (checkin)   :09:00, 15m
    猫猫旅行推进 (travel)          :09:00, 15m
    活跃地图连发点亮 (activity)     :10:00, 20m
    section 中午
    开学季活动任务 (school)        :12:00, 15m
    section 晚间
    二次签到 (checkin)             :21:00, 15m
    猫猫旅行再推进 (travel)         :21:00, 15m
    Token 全量保活 (keepalive)     :22:00, 20m
```

### 📋 六大任务详细说明与功能闭环

| 任务标识 (`name`) | 触发时刻 | 开关配置项 | 任务核心机制与闭环逻辑 |
| :--- | :---: | :--- | :--- |
| **`checkin`**<br>每日签到 | **09:00 / 21:00** | `schedule.checkin_enabled` | 每日签到并查询全账号积分余额；若检测到被冻结账号的余额恢复正常，**自动解除冷却解冻账号**。 |
| **`activity`**<br>活跃地图 | **10:00** | `schedule.activity_enabled` | 对话事件连发上报，点亮活跃地图与连登天数，解锁领养前置；自动使用补签卡保连登、连登档位兑换与抽奖、礼包/补偿领取，回读 streak 自检。 |
| **`travel`**<br>猫猫旅行 | **09:00 / 21:00** | `schedule.travel_enabled` | 领养 / 派出 / 领奖闭环推进，全流程自动化运行无需人工干预。 |
| **`keepalive`**<br>Token保活 | **22:00** | `schedule.keepalive_enabled` | 全账号自动刷新 token，仅在 session 失效连续累计 3 次时才禁用隔离账号，防止偶发网络抖动误杀。 |
| **`school`**<br>开学季任务 | **12:00** | `schedule.school_enabled` | 任务点亮 + claim 领取 + 自动抽空抽奖余额；若上游活动下线则自动跳过，优雅兼容。 |
| **`cat`**<br>夜猫子任务 | **01:00** | `schedule.cat_enabled` | 位于夜猫窗口（`23:00–08:00 CST`）内，自动补做一次 `black_cat` 专属积分任务。 |

---

### 🎲 确定性防封抖动机制 (`schedule.jitter_minutes`)

为了防止整点并发请求被上游 WAF / 风控识别，系统支持 **确定性时间抖动**：

- **缺省值**：`0`（精确整点触发，行为等同于系统 crontab 的 `0 9 * * *`）。
- **启用抖动**：在 `config.json` 中配置正整数（如 `30`），任务将在名义时点之后的 `0 ~ 30` 分钟窗口内摊开触发。
- **确定性散列派生**：
  $$\text{Offset} = \text{Hash}(\text{任务名} + \text{日期} + \text{小时}) \pmod {\text{jitter\_minutes}}$$
  - **重启幂等**：同一天同一任务的偏移量恒定，服务即使重启当天节奏完全一致，**绝不会在同一时点重复触发两次**；
  - **每日轮换**：换一天自动变换全新偏移时间，避免形成新的固定特征，对风控检测更友好；
  - **时序说明**：当抖动窗口大于相邻任务间隔时，实际执行先后顺序可能调整，这是平摊峰值负载的自然表现。

---

### 🔄 错过窗口手动补跑接口（零上游增量）

当遇到服务重启、服务器维护或刚添加新账号错过当期整点时，无需干等到下一个周期，支持即时补跑：

#### 1. HTTP API 补跑（管理端点）
- **请求格式**：
  ```bash
  POST /admin/tasks/{name}/run
  # name 可选值：checkin / activity / keepalive / travel / school / cat
  ```
- **请求示例**：
  ```bash
  curl -s -X POST http://127.0.0.1:7863/admin/tasks/checkin/run \
       -H "Authorization: Bearer <API_KEY>"
  ```
- **核心特性**：
  - **202 Accepted 异步受理**：因为全池任务遍历打上游可能耗时数分钟，接口立即返回 202，后台异步排程补跑，进度直接输出在网关日志中；
  - **409 Conflict 防连点**：若当前任务已有一趟在跑，立即返回 `409`，彻底避免并发连点对上游造成重复写；
  - **零上游增量**：仅将既有任务提前执行一次，不额外增加任何多余请求。

#### 2. CLI 命令行快捷补跑
直接进入容器或使用宿主机快捷命令：
```bash
docker exec -it workbuddy2api ./acct.sh task checkin
# 支持参数：checkin / activity / keepalive / travel / school / cat
```

---

## 🔒 安全保障与凭据管理

### 1. 凭据存储文件 (`.credentials`)
所有核心凭据保存在 `<BASE_DIR>/.credentials`，权限设为 **`0600`**（仅 root 可读）：
```bash
# 查看部署生成的凭据
cat /opt/wb2api/.credentials
```
包含以下项：
- `API_KEY`：网关内部通信与管理接口调用密钥
- `ADMIN_PASSWORD`：面板管理员密码
- `MANAGER_API_KEY`：对外 API 客户端调用密钥（格式为 `wbk_...`）

### 2. 重要数据风险防范说明
> [!WARNING]
> **密码变更提示**：若后续通过 `-p` 重新指定密码，脚本会自动重置面板数据库以重新注册 `admin`。重置过程会使已登录的 session 失效。若日常需要修改密码，建议直接在面板网页端后台修改。

---

## 🛠️ 客户端接入示例

在任意兼容 OpenAI API 的客户端（如 **Cherry Studio**、**NextChat**、**Chatbox**、**Open-WebUI**）中配置：

- **API 协议**：`OpenAI 兼容`
- **Base URL**：`https://你的域名/v1`（或 `http://127.0.0.1:7864/v1`）
- **API Key**：填入 `.credentials` 中的 `MANAGER_API_KEY`
- **模型名称**：在面板扫码纳管账号后，会自动同步可调用的模型列表。

---

## 📈 实机验证记录 (Debian 12 1GB VPS)

在配置仅为 1 核心、960MB 内存的云服务器上进行全链路自动化测试，全流程耗时 **42 秒** 完成初始化：
```text
[01] 环境预检：docker 29.x, compose 5.x, 可用内存 381MB (通过)
[02] 依赖检测：识别到已运行的 Nginx，自动跳过 Caddy 规避端口冲突 (通过)
[03] 容器启动：workbuddy2api (256M 限制), workbuddy-manager (320M 限制) 正常就绪
[04] 流式输出：SSE 打字机传输无卡顿，600s 长连接保持稳定
[05] 自动签发：API 密钥经重试自愈成功创建并持久化存储
[06] 任务调度：6 大定时积分任务与散列抖动引擎启动，/admin/tasks/{name}/run 端点就绪
```

---

## 📄 开源许可与致谢

- **网关本体与定时任务引擎**：[HanawaBanana/workbuddy2api](https://github.com/HanawaBanana/workbuddy2api) (原 [Sliverkiss/workbuddy2api](https://github.com/Sliverkiss/workbuddy2api)) (MIT License)
- **面板本体**：[ithtelab/workbuddy-manager](https://github.com/ithtelab/workbuddy-manager) (MIT License)
- **特别致敬与感谢**：[kejilion.sh (科技Lion Linux 工具箱)](https://kejilion.sh/) — 感谢科技Lion团队为 Linux VPS 运维带来的杰出一键化建站、反向代理与 SSL 体验，本脚本深度融合了科技Lion环境，实现了无缝共存与零冲突协同。
- **协议**：本一键部署与反代增强套件遵循 MIT 开源协议。


