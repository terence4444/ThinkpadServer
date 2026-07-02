# 电池保护与停电自动优雅关机方案

作为 7x24 小时插电运行的服务器，笔记本的电池极易因长期处于 100% 满电状态而导致**鼓包**，甚至引发火灾隐患。同时，遇到物理停电时，必须有自动优雅关机的防灾机制。

---

## 1. 充电阈值设置（保护电池）

### 核心痛点
ThinkPad 官方 BIOS 通常不提供充电上限设置。如果直接插着电源 7x24 小时运行，电池长期处于 100% 满电且受热，极易发生鼓包。

### 解决方案
在 Linux 字符界面下，使用 `TLP` 守护进程将充电阈值写入主板 EC（嵌入式控制器）芯片。

### 配置步骤
1.  **安装 TLP 工具**:
    ```bash
    # Debian/Ubuntu 
    sudo apt update && sudo apt install -y tlp
    # RHEL/CentOS (需先启用 EPEL 源)
    sudo dnf install -y tlp
    ```
2.  **配置充电阈值**:
    编辑 `/etc/tlp.conf`（或在 `/etc/tlp.d/` 下新建自定义配置文件），修改或加入以下配置：
    ```ini
    # 启用 TLP 总开关
    TLP_ENABLE=1
    
    # 设置电池充电阈值（适用于主电池 BAT0）
    # 当电量低于 60% 时开始充电，达到 65% 时停止充电
    START_CHARGE_THRESH_BAT0=60
    STOP_CHARGE_THRESH_BAT0=65
    ```
3.  **启动并应用服务**:
    ```bash
    sudo tlp start
    ```
4.  **生效验证**:
    配置成功后，TLP 会将此阈值直接写入主板 EC 芯片。**即使关机或重装系统，该限制依然在主板硬件层面生效**，电池电量将永久保持在 60%~65% 之间，彻底消除鼓包隐患。

---

## 2. 停电 40% 自动优雅关机、安全钩子与自愈重启方案 (防灾脚本)

当遭遇电网停电、漏电保护器跳闸等意外断电时，虽然笔记本电池可以充当临时 UPS，但电量耗尽后的突然断电仍会导致数据库或应用服务损坏。

### 核心设计与自愈逻辑
为保障数据完整性并解决物理服务器经典的“关机自动开机失效”问题，本系统采用了**基于 Systemd 原生状态检测**、**PID 并发追踪**、以及**来电热重启自愈**的先进方案：

1.  **短轮询检测（每5分钟）与 11 分钟关机时差设计**: 
    - 脚本由系统的 Cron 服务每 5 分钟自动调度执行一次。
    - **为什么要将关机时间设为 11 分钟而非 10 分钟？** 这是一个极致的细节优化。如果检测周期是 5 分钟，而关机时间是 10 分钟，那么第二次检测时间（第 10 分钟）会精确撞上系统关机的时刻。在此时刻，Cron 服务或网络可能已经关闭，脚本大概率失去拦截并执行自愈重启的机会。
    - **通过设为 11 分钟 (`shutdown -h +11`)**: 第一次检测在第 5 分钟，第二次检测在第 10 分钟。此时距离最终关机还有整整 **1分钟** 的安全操作窗口。脚本有充足的裕度去检测是否恢复供电、取消关机并安全等待落盘后执行自愈重启，极大降低了由于来电错位而导致自愈失效的概率！
2.  **触发阈值**: 当检测到系统处于**放电状态（电池供电）**且**电量低于 40%** 时触发。
3.  **原生无锁状态检测**: 
    - 脚本不使用任何自定义磁盘锁文件。
    - 而是通过读取 Systemd 原生在倒计时关机时生成的内存状态文件 `/run/systemd/shutdown/scheduled`。
    - 只要有计划关机，该文件就存在；取消关机后文件自动销毁。这避免了因为“残留锁文件”导致的状态失同步风险。
4.  **模块化并发钩子与 PID 追踪 (Modular Hooks)**:
    - 触发关机倒计时 (`shutdown -h +11`) 的同时，脚本将并发在后台运行 `/etc/power_monitor.d/` 目录下的所有自定义服务关闭脚本。
    - 脚本会在运行的同时，将它们的进程 ID 写入 `/run/power_monitor_hooks.pids`，进行精细化的进程级别追踪。
5.  **高安全度来电热重启自愈 (Warm-Reboot)**:
    - **痛点一 (BIOS AC 接入开机失效)**: 如果在 11 分钟倒计时内电源恢复了，如果任由系统关机，由于关机时 AC 插头已插在笔记本上，主板检测不到“无 AC -> 有 AC”的跳变，笔记本将永远无法自动开机。因此**必须撤销关机**。
    - **痛点二 (服务破坏与数据库损坏)**: 撤销关机后，如果直接不管或者立刻强行重启，若此时 ClickHouse/S4HANA 的关闭脚本还在后台执行数据刷盘，强行中断会造成数据库损坏。
    - **完美解法**: 
      1. 一旦检测到电源恢复，立即调用 `shutdown -c` 撤销关机，锁定系统不断电。
      2. 循环检查 `/run/power_monitor_hooks.pids` 中的进程状态，**等待所有运行中的关闭脚本安全执行完毕（最多等待 5 分钟）**，确保数据已完全安全落盘。
      3. 确认所有钩子完全退出后，立即下发 `/sbin/reboot` **执行系统热重启**。
      4. 系统热重启后，所有被关掉的数据库和应用服务将通过 Systemd 的开机自启干净地重新加载，恢复正常服务，完美闭环！

---

### 自动化脚本 `power_monitor.sh`
该监控脚本已升级并存放于本仓库的 `scripts/common/power_monitor.sh` 中。你可以直接查阅或复制该文件：

👉 **[查看/复制完整脚本文件：scripts/common/power_monitor.sh](../../scripts/common/power_monitor.sh)**

---

### 模块化钩子 (Custom Shutdown Hooks)
本仓库在 `scripts/common/shutdown.d/` 目录下提供了模块化优雅关机的脚本模板：

*   👉 **[ClickHouse 优雅关机模板：scripts/common/shutdown.d/10_clickhouse.sh](../../scripts/common/shutdown.d/10_clickhouse.sh)**
*   👉 **[SAP S/4HANA & HANA 优雅关机模板：scripts/common/shutdown.d/20_s4hana.sh](../../scripts/common/shutdown.d/20_s4hana.sh)**

---

### 部署与配置步骤

#### 1. 部署主监控脚本
将仓库中的监控脚本复制到服务器的 `/usr/local/bin/power_monitor.sh` 并赋予执行权限：
```bash
sudo cp scripts/common/power_monitor.sh /usr/local/bin/power_monitor.sh
sudo chmod +x /usr/local/bin/power_monitor.sh
```

#### 2. 创建自定义钩子目录并部署服务脚本
根据您的服务器角色（ClickHouse 节点或 SAP S/4HANA 节点），将对应的钩子脚本复制到系统自定义目录：
```bash
# 创建自定义钩子目录
sudo mkdir -p /etc/power_monitor.d

# 根据部署角色拷贝钩子（例如 ClickHouse 节点）
sudo cp scripts/common/shutdown.d/10_clickhouse.sh /etc/power_monitor.d/

# 确保钩子脚本有执行权限
sudo chmod +x /etc/power_monitor.d/*
```

#### 3. 设置定时任务 (Cron)
使用 `sudo crontab -e` 配置每 5 分钟自动轮询一次：
```cron
# 每 5 分钟执行一次电源监控脚本，自动处理断电防灾与自愈重启
*/5 * * * * /usr/local/bin/power_monitor.sh
```
