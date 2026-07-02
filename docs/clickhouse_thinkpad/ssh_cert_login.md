# ClickHouse 测试系统：极简 SSH 证书登录与免密 Sudo 配置指南

对于开发与测试系统，我们无需像在严苛生产环境中那样建立复杂的“离线安全 CA 主机”或频繁更新“吊销列表 (KRL)”。为了追求**最高效的运维体验**，我们可以进行适当简化：
1. **本地扮演 CA**: 直接在 ClickHouse 宿主机本地生成 CA 根密钥，省略跨机器拷贝和传输公钥的步骤。
2. **极长有效期**: 签发超长有效期（如 10 年）的证书，免去频繁续签的运维琐事。
3. **免密 Sudo 极速提权**: 将“免密 Sudo”作为默认的核心权限机制，确保在终端进行 ClickHouse 高频调试与系统部署时，体验极致丝滑。
4. **保留密码备份**: 暂时保留常规密码登录作为防失联的最后兜底备份。

---

## 1. 极简架构设计 (测试系统特化)

```text
+---------------------------------------------------------+
| ClickHouse 目标服务器 (Debian 13)                        |
|                                                         |
|  1. 本地 CA 角色: [/etc/ssh/ssh_ca] (无需输入密码)         |
|  2. SSH 信任注册: 信任本地的 [ssh_ca.pub]                 |
|  3. 账户与提权:  用户 alice 属于 sudo 组 (免密 Sudo 模式)  |
+----------------------------^----------------------------+
                             |
                   1. 客户端发送 id_ed25519.pub
                   2. 服务器本地签发 10 年证书发回
                   3. 客户端凭证书极速登录 (无密且无密码提示)
                             |
                  +----------+----------+
                  | 客户端 (运维用户 Alice) |
                  | [id_ed25519-cert]   |
                  +---------------------+
```

---

## 2. 步骤一：本地化 CA 极简初始化

在测试系统上，我们可以直接在 ClickHouse 主机上扮演 CA，并且**不设私钥保护密码**以实现极简管理。

在 ClickHouse 宿主机运行：
```bash
# 在 /etc/ssh 目录下直接创建 CA 密钥对，且 -N "" 表示私钥密码为空
sudo ssh-keygen -t ed25519 -N "" -f /etc/ssh/ssh_ca -C "Test-System SSH CA"

# 确保私钥仅 root 可读，公钥允许全局读取
sudo chmod 600 /etc/ssh/ssh_ca
sudo chmod 644 /etc/ssh/ssh_ca.pub
```

---

## 3. 步骤二：目标服务器信任注册

因为 CA 就在本地，我们省去了传输的过程，直接配置本机 SSH 信任该 CA 公钥。

### 1. 修改 SSH 配置
编辑宿主机的 `/etc/ssh/sshd_config`（或在 `/etc/ssh/sshd_config.d/` 新建 `.conf` 文件），追加以下一行：

```ini
# 注册并信任本机的 CA 公钥
TrustedUserCAKeys /etc/ssh/ssh_ca.pub

# 【测试系统便利】：保留密码登录作为防失联兜底（无需设为 no）
PasswordAuthentication yes
```

### 2. 配置自检与服务重启
```bash
# 检查 SSH 配置文件是否有语法错误
sudo sshd -t

# 语法无误后，重启 SSH 服务生效 (Debian 13 的服务名为 ssh)
sudo systemctl restart ssh
```

---

## 4. 步骤三：创建本地运维账户与免密 Sudo 配置

多用户登录仍需在服务器上建立对应的本地同名 Unix 账户。在这里我们选择 **免密 Sudo 提权** 方案。

### 1. 创建本地用户
假设有两位运维用户 `alice` 和 `bob`：
```bash
# 极简创建账户，不为他们设置初始密码（只能通过证书/常规公钥登录）
sudo adduser --disabled-password --gecos "" alice
sudo adduser --disabled-password --gecos "" bob
```

### 2. 赋予 Sudo 组特权
将这些用户加入 `sudo` 组：
```bash
sudo usermod -aG sudo alice
sudo usermod -aG sudo bob
```

### 3. 一键配置免密 Sudo
直接写入自定义 Sudo 规则，使 `sudo` 组内所有用户提权时无需输入任何密码，实现体验的绝对无缝：
```bash
# 写入免密规则到特化配置文件
echo "%sudo ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/90-sudo-cert-users

# 确保该规则文件权限正确
sudo chmod 440 /etc/sudoers.d/90-sudo-cert-users
```

---

## 5. 步骤四：证书签发与分发 (两种可选方案)

根据团队运维习惯与安全等级，可以选择以下任意一种方案进行证书签发和分发：

### 方案 A：管理员统一生成与分发 (开发/测试环境极速推荐 🚀)
*最省心的方案，新用户零命令行门槛。由管理员在服务器直接生成密钥对和证书，通过密码管理器发送给用户。*

#### 1. 管理员在服务器上为新用户生成密钥对并签发证书
假设要为新运维人员 `jack` 建立访问：
```bash
# 1. 直接在服务器临时目录生成密钥对（-N "" 表示不设私钥密码）
ssh-keygen -t ed25519 -N "" -f /tmp/jack_id_ed25519 -C "jack@company"

# 2. 签发 10 年有效期（+520w）的证书，仅允许其以本地 jack 账户登录
sudo ssh-keygen -s /etc/ssh/ssh_ca \
           -I "clickhouse_test_jack" \
           -n jack \
           -V +520w \
           /tmp/jack_id_ed25519.pub
```
*这将在 `/tmp` 目录下生成三个文件：私钥 `jack_id_ed25519`、公钥 `jack_id_ed25519.pub` 以及证书 `jack_id_ed25519-cert.pub`。*

#### 2. 安全分发
管理员将以下两个关键文件通过安全密码管理器（如 Bitwarden、1Password 或其他加密渠道）安全分发给 Jack：
1. **私钥文件**：`jack_id_ed25519` (Jack 收到后需放入 `~/.ssh/` 并更名为 `id_ed25519`，且 `chmod 600`)
2. **证书文件**：`jack_id_ed25519-cert.pub` (Jack 收到后需放入 `~/.ssh/` 并更名为 `id_ed25519-cert.pub`)

---

### 方案 B：客户端自主生成，管理员单向签发 (经典安全方案 🔒)
*标准的安全做法，私钥全程不离用户本机，确保管理员也无法获取用户的私钥。*

#### 1. 客户端生成密钥对
Alice 在其本地电脑（Windows/macOS/Linux）的命令行中生成密钥对：
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "alice@laptop"
```
Alice 将其生成的公钥 `~/.ssh/id_ed25519.pub` 发送给管理员。

#### 2. 服务器管理员在本地签发 10 年证书
管理员拿到公钥（假设临时保存为服务器的 `/tmp/alice_id_ed25519.pub`）后，在服务器运行：
```bash
# 签发 10 年有效期（+520w）的证书，仅允许其以本地 alice 账户登录
sudo ssh-keygen -s /etc/ssh/ssh_ca \
           -I "clickhouse_test_alice" \
           -n alice \
           -V +520w \
           /tmp/alice_id_ed25519.pub
```
*这将在同目录下生成 `/tmp/alice_id_ed25519-cert.pub` 证书。*

#### 3. 返回证书
管理员将 `/tmp/alice_id_ed25519-cert.pub` 证书文件发回给 Alice 即可。

---

## 6. 步骤五：客户端极速登录

根据客户端工具的不同，选择以下对应的配置方式：

### 1. 方式一：标准 OpenSSH 客户端 (Linux/macOS/Windows Terminal)
Alice 收到证书后，将其重命名并放置在本地电脑的 `~/.ssh/` 目录下。
* **私钥路径**：`~/.ssh/id_ed25519` (Linux/macOS 下需执行 `chmod 600 ~/.ssh/id_ed25519`)
* **证书路径**：`~/.ssh/id_ed25519-cert.pub` (必须与私钥同名，且带 `-cert.pub` 后缀，SSH 登录时会自动识别)

在本地电脑终端中直接运行：
```bash
# 证书验证将自动无密码登录
ssh alice@<clickhouse-server-ip>
```

---

### 2. 方式二：PuTTY 客户端 (Windows 端极简单文件集成 🚀)
从 **PuTTY 0.78 及以上版本**开始，PuTTYgen 支持**将 OpenSSH 证书直接内嵌集成到 `.ppk` 私钥中**。这样管理员或用户最终只需分发/保管**单个 `.ppk` 文件**，极为优雅。

#### 第一步：使用 PuTTYgen 生成内嵌证书的 `.ppk`
1. 打开 **PuTTYgen**。
2. 点击 **Load** 按钮，导入管理员分发的 OpenSSH 格式私钥文件（如 `jack_id_ed25519`）。
3. 导入成功后，点击顶部菜单栏的 **Key** -> **Add certificate to key**。
4. 浏览并选择对应的证书文件 **`jack_id_ed25519-cert.pub`**。
   *(此时你会注意到“Public key for pasting”区域变成了展示证书详情的按钮。注意：PuTTYgen 底部默认的 Parameters RSA 2048 仅对生成新密钥生效，不会影响已导入的 Ed25519 密钥性质)*
5. 点击 **Save private key**，将其保存为全新的 **`jack_id_ed25519.ppk`** 文件。该文件内部已完美融合了私钥和证书。

#### 第二步：在 PuTTY 中加载并登录
1. 打开 **PuTTY**，展开左侧树状菜单：**Connection -> SSH -> Auth -> Credentials**。
2. 在 **Private key file for authentication** 框中，点击 **Browse** 导入刚才生成的内嵌版 `jack_id_ed25519.ppk`。
3. *(可选)* 展开左侧 **Connection -> Data**，在 **Auto-login username** 中填入服务器同名账户（如 `jack`），省去手动敲用户名的步骤。
4. 返回 **Session** 页面保存会话，点击 **Open**，即可实现一键免密极速登录！

---

### 3. 登录后的无感 Sudo 提权测试
无论使用哪种客户端，登录进入终端后，由于我们在步骤三中配置了免密 Sudo，均可执行：
```bash
# 完美的免密提权，不会提示任何密码输入
sudo -i
```

---

## 7. 💡 测试系统运维技巧与向生产过渡

### 1. 用户离职或密钥丢失如何快速处理？
在测试系统中，如果 Alice 的电脑丢失或由于岗位变动需要收回权限，由于我们简化了吊销列表（KRL）的维护，最快的删除手段是：
```bash
# 在 ClickHouse 服务器上，直接删除其本地 Unix 用户即可，其证书将自动失效
sudo userdel -r alice
```

### 2. 未来系统向生产环境过渡时的加固指南
如果当前测试系统后续需要承载核心生产数据，请在安全性上做如下加固过渡：
1. **CA 私钥物理迁移**: 将 `/etc/ssh/ssh_ca`（私钥）安全迁移到独立的离线安全管理机上保存，并**从 ClickHouse 主机上彻底删除该私钥**。
2. **重设私钥密码**: 生产环境下的 CA 私钥必须设定复杂的 Passphrase。
3. **压缩证书期限**: 生产环境下的证书建议限制在 `+1w` (1周) 或 `+52w` (1年)，强制进行定期滚动续签。
4. **安全关闭回退**: 一旦所有运维人员均适配证书登录，在 `/etc/ssh/sshd_config` 中将 `PasswordAuthentication yes` 修改为 `no`，彻底杜绝任何外部密码扫描。
