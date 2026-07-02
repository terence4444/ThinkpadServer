# ClickHouse 沙盒服务器：系统崩溃快速恢复（灾备与分钟级重建）指南

沙盒系统作为公司内网 VPN 下的开发验证与打包安装测试环境，面临着**测试包高频迭代、软件依赖冲突、高负载崩溃、以及由于高权限（免密 Sudo）误操作导致系统损坏**等痛点。

本篇针对 Thinkpad 物理服务器（Debian 13）的物理隔离分区特性（100G 系统盘 `/` 与 1.8T+ 独占数据盘 `/data` 物理隔离），制定了一套**分级容灾与分钟级快速恢复指南**。

---

## 1. 快速恢复战略：分级容灾与 RTO

为了实现极高的开发测试连续性，我们将系统崩溃划分为三种场景：

| 故障场景 | 恢复级别 | 恢复目标时间 (RTO) | 核心做法 |
| :--- | :--- | :--- | :--- |
| **误删配置/凭签丢失/提权锁死** | **Level 1**: 凭证与系统层 | **< 1 分钟** | 从物理隔离的 `/data` 备份区分秒级还原 SSH CA 私钥与免密 Sudo 规则。 |
| **测试数据污染/数据库爆满挂起** | **Level 2**: 应用与数据层 | **< 5 分钟** | 一键抹除并快速重建 `/data` 专属分区，秒级加载 ClickHouse 的最简 DDL 结构。 |
| **系统玩坏/引导彻底坏死/误删根目录**| **Level 3**: 裸机与 OS 重装 | **< 20 分钟** | 插入 Debian 13 U 盘快速重装系统盘 `/`，随后运行「一键自动化 Bootstrap 脚本」秒级复原整套沙盒环境。 |

---

## 2. Level 1: 凭证与系统配置的“秒级复原”

利用独立 SSD 分区 `/data` 的隔离性：**即便根系统 `/` 被彻底擦除或重装，`/data` 分区中的文件依然完好无损。** 我们将整套系统的灵魂（SSH CA、Sudo 规则、用户名单）每天定时备份至 `/data` 下。

### 1. 极简本地定时备份脚本
在宿主机创建备份脚本 `/data/scripts/backup_auth.sh`：
```bash
#!/bin/bash
# 备份核心凭证与用户规则
BACKUP_DIR="/data/backup/system_auth"
mkdir -p "$BACKUP_DIR"

# 打包备份：SSH CA 秘钥对、Sudo 免密规则、系统用户名单（/etc/passwd, /etc/group, /etc/shadow）
tar -czf "$BACKUP_DIR/auth_daily_latest.tar.gz" \
    /etc/ssh/ssh_ca* \
    /etc/ssh/sshd_config.d/* \
    /etc/sudoers.d/90-sudo-cert-users \
    /etc/passwd /etc/group /etc/shadow \
    2>/dev/null

echo "[$(date)] Auth backup completed." >> /data/backup/backup.log
```
*提示：通过 `sudo crontab -e` 设定每日凌晨 3 点自动运行。*

### 2. 发生灾难时的秒级还原命令
如果您不小心写坏了 Sudoers、丢失了 CA 私钥、或重装了系统盘，只需挂载 `/data`，然后运行：
```bash
# 解压覆盖回系统根目录
sudo tar -xzf /data/backup/system_auth/auth_daily_latest.tar.gz -C /

# 重启 SSH 服务，免密登录与 CA 信任瞬间复原
sudo systemctl restart ssh
```

---

## 3. Level 2: ClickHouse 结构与测试数据快速抹除重建

在高频验证测试包时，ClickHouse 经常被塞满脏数据，或者由于写入配置错误导致进程死锁、磁盘空间耗尽。

### 1. 极速抹除脏数据并重置 ClickHouse 存储
无需重装系统，直接执行物理级格式化抹除 `/data`，重新挂载并恢复 ClickHouse 所需目录：
```bash
# 1. 停止 ClickHouse 服务
sudo systemctl stop clickhouse-server

# 2. 卸载并快速格式化 /data 分区 (根据实际 UUID 或设备名，此处以 /dev/sdb1 为例)
sudo umount /data
sudo mkfs.ext4 -F /dev/sdb1

# 3. 重新挂载并应用 ext4 写入寿命优化参数（照应 partition.md）
sudo mount -o noatime,nodiratime,nodev,nosuid /dev/sdb1 /data

# 4. 秒级重建 ClickHouse 主数据目录与缓存目录
sudo mkdir -p /data/clickhouse/data /data/clickhouse/tmp /data/clickhouse/format
sudo chown -R clickhouse:clickhouse /data/clickhouse
sudo chmod 750 /data/clickhouse

# 5. 重新启动 ClickHouse 服务
sudo systemctl start clickhouse-server
```

### 2. 极简 Schema DDL 快速导入
测试环境最重要的是**表结构 DDL**，而非海量脏数据。我们在 `/data/backup/clickhouse/` 下长期保留一个 `schemas.sql` 结构包：
```bash
# 快速备份当前的库表结构（不含数据）
clickhouse-client --query "SHOW CREATE DATABASE test_db" > /data/backup/clickhouse/schemas.sql
clickhouse-client --database=test_db --query "SHOW TABLES" | while read table; do
    clickhouse-client --query "SHOW CREATE TABLE test_db.$table" >> /data/backup/clickhouse/schemas.sql
done

# 灾后一键恢复库表结构
clickhouse-client < /data/backup/clickhouse/schemas.sql
```

---

## 4. Level 3: 操作系统死锁损坏——一键快速重建（Bootstrap）脚本

当系统盘被不小心彻底破坏（如引导扇区损坏、底层 libc 库被污染、或者 `rm -rf /` 误操作），您需要：
1. 插入 Debian 13 原版 U 盘，在 10 分钟内完成最简系统重装（只安装核心系统，不勾选任何图形界面和额外软件包）。
2. 重装完成后，挂载并直接执行存在 `/data` 下的 **一键自动化 Bootstrap 脚本**。

在 `/data/scripts/bootstrap_sandbox.sh` 下存放此脚本（一次编写，终身受益）：

```bash
#!/bin/bash
# =====================================================================
# Debian 13 Sandbox Bare-Metal Bootstrap Script
# 适用场景：物理机重装系统盘后，一键恢复挂载、调优、工具、免密登录与数据库
# =====================================================================

set -e
echo "🚀 开始极速重建沙盒服务器环境..."

# 1. 检测 /data 挂载状态
if ! mountpoint -q /data; then
    echo "⚙️ 挂载 /data 分区..."
    # 自动获取 /dev/sdb1 (数据分区) 的 UUID 并写入 /etc/fstab
    DATA_UUID=$(blkid -s UUID -o value /dev/sdb1 || echo "")
    if [ -n "$DATA_UUID" ]; then
        echo "UUID=$DATA_UUID /data ext4 defaults,noatime,nodiratime,nodev,nosuid 0 2" | tee -a /etc/fstab
        mkdir -p /data
        mount /data
    else
        echo "❌ 错误：未找到 /dev/sdb1 分区！"
        exit 1
    fi
fi

# 2. 内核 Swappiness 调优 (物理防 OOM 安全气囊)
echo "⚙️ 配置内核 swappiness = 10..."
sysctl vm.swappiness=10
echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf

# 3. 更新源并一键安装系统基础工具
echo "⚙️ 补充系统常用基础组件..."
apt-get update -y
apt-get install -y curl btop ufw git ca-certificates gnupg

# 4. 导入 ClickHouse 官方源并安装
echo "⚙️ 安装 ClickHouse 列式数据库..."
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key | gpg --dearmor -o /etc/apt/keyrings/clickhouse-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" | tee /etc/apt/sources.list.d/clickhouse.list
apt-get update -y
# 非交互式安装 ClickHouse (无密码)
DEBIAN_FRONTEND=noninteractive apt-get install -y clickhouse-server clickhouse-client

# 5. 物理还原凭证与多用户 SSH 体系
echo "⚙️ 恢复多用户凭证及 SSH CA 验证..."
if [ -f "/data/backup/system_auth/auth_daily_latest.tar.gz" ]; then
    tar -xzf /data/backup/system_auth/auth_daily_latest.tar.gz -C /
    systemctl restart ssh
    echo "✅ 成功复原多用户账号、Sudo 免密规则与 SSH CA 密钥链！"
else
    echo "⚠️ 警告：未在 /data 下找到凭证备份包，跳过此步..."
fi

# 6. 配置防火墙安全放行 (内网 VPN 网段全放通)
echo "⚙️ 配置内网安全防火墙..."
ufw default deny incoming
ufw default allow outgoing
ufw allow from 10.0.0.0/8 to any comment 'Allow Corporate VPN'
ufw --force enable

echo "🎉 沙盒服务器极速重建完成！"
echo "👉 请尝试在客户端直接使用 ssh-cert 免密登录，并验证 sudo -i 无阻断。"
```

---

## 5. 💡 沙盒系统快速应急恢复“三板斧” (应急速查)

### 1. 第一斧：网卡丢 IP 或拔插网线网卡不工作
由于 Thinkpad 是物理机，网线松动、拔插或局域网交换机波动，可能导致在 headless（无图形）环境下网卡死掉。
* **极速重启网络**:
  ```bash
  sudo systemctl restart networking
  # 若仍未获取 IP，强行重新拉起网卡并请求 DHCP
  sudo ip link set dev eth0 down && sudo ip link set dev eth0 up && sudo dhclient eth0
  ```

### 2. 第二斧：磁盘爆满（100%）导致 SSH 无法连接/写入报错
如果打包测试产生了大量 core logs 或 Docker 镜像导致根盘 100% 锁死，SSH 无法登录：
* **抢救步骤**:
  1. 通过 Thinkpad 自带键盘与屏幕直接切到物理控制台（`Ctrl + Alt + F2`）。
  2. 使用常规密码登录 root（或高特权账户）。
  3. 执行一键安全清理：
     ```bash
     # 清空 systemd 庞大的历史日志
     sudo journalctl --vacuum-size=50M
     # 清除 apt 构建缓存
     sudo apt-get clean
     # 删除 dangling Docker 缓存镜卷
     docker system prune -af --volumes 2>/dev/null || true
     ```

### 3. 第三斧：Sudoers 语法写错，导致 sudo 锁死无法提权
如果不小心手动编辑 `/etc/sudoers` 或 `/etc/sudoers.d/90-sudo-cert-users` 产生语法错误，`sudo` 命令会直接锁死并报错退出，无法进行任何 root 行为。
* **抢救方法 (免重装)**:
  在 Debian 上，如果你还有当前登录的终端或物理控制台，且系统中安装了 `policykit-1`：
  ```bash
  # 使用 pkexec（PolicyKit 独立鉴权器）绕过 sudo 直接调用文本编辑器修复
  pkexec nano /etc/sudoers.d/90-sudo-cert-users
  ```
  *如果 pkexec 也不可用，需重启 Thinkpad 物理机，开机引导时按下 `e` 进入 GNU GRUB，在 `linux` 行末尾追加 `init=/bin/bash` 进入极简单用户 root shell，再执行 `/usr/sbin/visudo` 强制修好语法，随后重启。*
