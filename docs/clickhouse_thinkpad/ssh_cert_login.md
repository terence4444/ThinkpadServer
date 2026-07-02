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
sudo adduser --gecos "" alice
sudo adduser --gecos "" bob
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

## 5. 步骤四：极速证书签发与分发

当有新运维人员 Alice 需要加入并需要登录时，其签发过程极其快速。

### 1. 客户端生成密钥对
Alice 在其本地电脑（Windows/macOS/Linux）的命令行中生成密钥对：
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "alice@laptop"
```
Alice 将其公钥 `~/.ssh/id_ed25519.pub` 发送给服务器管理员（也可以通过聊天工具发给管理员临时粘贴）。

### 2. 服务器管理员在宿主机本地签发 10 年证书
管理员拿到 Alice 的公钥（假设临时保存在服务器的 `/tmp/alice_id_ed25519.pub`）后，在服务器直接运行：
```bash
# 签发 10 年有效期（+520w）的证书，仅允许其以本地 alice 账户登录
sudo ssh-keygen -s /etc/ssh/ssh_ca \
           -I "clickhouse_test_alice" \
           -n alice \
           -V +520w \
           /tmp/alice_id_ed25519.pub
```
*这将在同目录下生成 `/tmp/alice_id_ed25519-cert.pub` 证书。*

### 3. 返回证书
管理员将 `/tmp/alice_id_ed25519-cert.pub` 文件发回给 Alice。

---

## 6. 步骤五：客户端极速登录

### 1. 放置证书
Alice 收到证书后，将其重命名并放置在本地电脑的 `~/.ssh/` 目录下。
* 私钥路径：`~/.ssh/id_ed25519`
* 证书路径：`~/.ssh/id_ed25519-cert.pub` (必须与私钥同名，且带 `-cert.pub` 后缀)

### 2. 登录与无感提权测试
在本地电脑终端中直接运行：
```bash
# 证书验证将自动无密码登录
ssh alice@<clickhouse-server-ip>
```
进入终端后，Alice 需要部署 ClickHouse 服务、重载配置或查看系统负载时，可以执行：
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
