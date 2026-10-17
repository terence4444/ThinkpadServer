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
    # 当电量低于 58% 时开始充电，达到 64% 时停止充电
    START_CHARGE_THRESH_BAT0=58
    STOP_CHARGE_THRESH_BAT0=64
    ```
    > 电池名以 `ls /sys/class/power_supply/` 为准，如果是 `BAT1`，变量名也要相应改成 `..._BAT1`。
    >
    > 现状：P16CHD 当前配置的是 60/65，P16EQ1 起使用 58/64。
    >
    > **RHEL 10 上没有 TLP**（EPEL 10 里找不到这个包）。可以改用 systemd 服务在开机时直接写 sysfs，效果相同，P16EQ1 就是这样做的：
    > ```ini
    > # /etc/systemd/system/battery-charge-threshold.service
    > [Unit]
    > Description=Set battery charge thresholds (start 58%, stop 64%)
    > After=multi-user.target
    >
    > [Service]
    > Type=oneshot
    > ExecStart=/bin/sh -c 'B=/sys/class/power_supply/BAT0; echo 64 > $B/charge_control_end_threshold; echo 58 > $B/charge_control_start_threshold'
    > RemainAfterExit=yes
    >
    > [Install]
    > WantedBy=multi-user.target
    > ```
    > `systemctl daemon-reload && systemctl enable --now battery-charge-threshold.service`，然后用 `cat /sys/class/power_supply/BAT0/charge_control_{start,end}_threshold` 验证。
3.  **启动并应用服务**:
    ```bash
    sudo tlp start
    ```
4.  **生效验证**:
    配置成功后，TLP 会将此阈值直接写入主板 EC 芯片。**即使关机或重装系统，该限制依然在主板硬件层面生效**，电池电量将永久保持在 58%~64% 之间，彻底消除鼓包隐患。

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
      2. 循环检查 `/run/power_monitor_hooks.pids` 中的进程状态，**等待所有运行中的关闭脚本安全执行完毕（`HOOK_WAIT_TIMEOUT`，默认最多 60 分钟）**，确保数据已完全安全落盘。
         > ⚠️ 该等待时间**必须大于最慢的钩子**。停止 SAP HANA 可能远超 5 分钟，若在 `HDB stop` 执行中途重启，等于把数据库硬停 —— 对 `log_mode = overwrite` 的实例（无日志备份、不能前滚）风险尤其大。等待超时后脚本仍会重启，但会在日志中打出 WARNING 明确告知"可能有数据库被硬停"。
      3. 确认所有钩子完全退出后，立即下发 `/sbin/reboot` **执行系统热重启**。
      4. 系统热重启后，所有被关掉的数据库和应用服务将通过 Systemd 的开机自启干净地重新加载，恢复正常服务，完美闭环！

---

### 自动化脚本 `power_monitor.sh`
该监控脚本已升级并存放于本仓库的 `scripts/common/power_monitor.sh` 中。你可以直接查阅或复制该文件：

👉 **[查看/复制完整脚本文件：scripts/common/power_monitor.sh](../../scripts/common/power_monitor.sh)**

---

### 模块化钩子 (Custom Shutdown Hooks)
本仓库在 `scripts/common/shutdown.d/` 目录下提供了模块化优雅关机的脚本模板：

*   👉 **[ClickHouse 优雅关机模板：scripts/common/shutdown.d/10_clickhouse.sh](../../scripts/common/shutdown.d/10_clickhouse.sh)**（⚠️ 当前为空文件，尚待填写）
*   👉 **[SAP S/4HANA & HANA 优雅关机模板：scripts/common/shutdown.d/20_s4hana.sh](../../scripts/common/shutdown.d/20_s4hana.sh)**
*   👉 **[SAP NetWeaver ABAP & MaxDB 优雅关机模板：scripts/common/shutdown.d/30_netweaver_maxdb.sh](../../scripts/common/shutdown.d/30_netweaver_maxdb.sh)**（P16EQ1 / ERP 6.0 EQ1 在用）：先 `sapcontrol StopSystem ALL`，等所有实例停止，再 `dbmcli -U c -d <DBSID> db_offline`（DBSID 从 `DEFAULT.PFL` 的 `rsdb/dbid` 自动读取）。和 HANA 版一样不强杀数据库，停库期间会推迟关机。测试：`sudo DRY_RUN=1 /etc/power_monitor.d/30_netweaver_maxdb.sh`

> cron：除了 `crontab -e`，也可以用系统级的 `/etc/cron.d/power_monitor`（P16EQ1 用的就是这种）：`*/5 * * * * root /usr/local/bin/power_monitor.sh`。

S/4HANA 钩子的特殊行为：因为该 HANA 实例使用 `log_mode = overwrite`，脚本**绝不强杀数据库**，而是在 `HDB stop` 运行期间持续把系统关机时刻往后推（每次 `+10` 分钟，仅在剩余不足 180 秒时续期），直到数据库确认停止后才关机；只有电量跌到 `CRITICAL_BATTERY`（默认 8%）以下才放弃等待并立即有序关机。

---

### 开机启动脚本 (SAP S/4HANA)
来电自愈热重启后，需要按 **先数据库、后应用服务器** 的顺序把 S/4HANA 拉起来：

👉 **[SAP S/4HANA 启动脚本：scripts/common/s4hana_start.sh](../../scripts/common/s4hana_start.sh)**

该脚本与关机钩子共用同一份配置和同一把锁（`/run/s4hana_control.lock`），因此启动与停电关机不可能同时执行。它在启动前会做四项安全检查：**已接市电**、**电量不低于 40%**、**`/hana/*` 卷已挂载**、**没有待执行的关机计划** —— 这样即使系统是在停电中途用电池开机的，也不会去加载 192G 的内存数据库。脚本头部注释里附了可直接使用的 `s4hana.service` systemd unit。

```bash
sudo cp scripts/common/s4hana_start.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/s4hana_start.sh
sudo /usr/local/bin/s4hana_start.sh --dry-run   # 先空跑，确认识别到的 SID 与实例号
```

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

#### 4. 配置日志轮转 (Logrotate)

`/var/log/power_monitor.log` 会**无限增长** —— 因为 dispatcher 把所有钩子的输出（`sapcontrol`、`HDB stop`、`HDB info` 的完整回显）都重定向进了这个文件，一次停电事件就可能写入相当可观的内容。而 `/var` 被写满会破坏**这套防灾机制本身**：关机脚本连日志都写不进去。

本仓库提供了现成的轮转规则：👉 **[configs/common/logrotate.d/power_monitor](../../configs/common/logrotate.d/power_monitor)**

```bash
sudo cp configs/common/logrotate.d/power_monitor /etc/logrotate.d/power_monitor
sudo chmod 0644 /etc/logrotate.d/power_monitor
sudo chown root:root /etc/logrotate.d/power_monitor

# 校验语法并预演（--debug 只打印计划动作，不真正改文件）
sudo logrotate --debug /etc/logrotate.d/power_monitor
```

策略说明：

| 指令 | 作用 |
| :--- | :--- |
| `daily` + `rotate 180` | 按天切割，保留 **180 天**历史 |
| `maxsize 20M` | 单个日志超过 20MB 就**提前**切割，不必等到当天结束 —— 防止某个钩子卡死时刷爆磁盘 |
| `dateext` | 归档名为 `power_monitor.log-20260811`，180 份 `.1 .2 .3` 根本没法查 |
| `compress` | 180 天纯文本没必要不压缩 |
| `copytruncate` | **关键项**，见下 |

> ⚠️ **为什么必须用 `copytruncate` 而不是默认的 rename + create？**
> `power_monitor.sh` 以 `"$script" >> "$LOG_FILE" 2>&1 &` 启动钩子，像 `20_s4hana.sh` 这样的钩子会在停 HANA 的**整个过程中**一直持有这个文件句柄。若用默认的改名重建，正在运行的钩子会继续往**已被改名的旧 inode** 里写，于是你最关心的那次停电事件，在 `power_monitor.log` 里看起来是空的。
> 而 `copytruncate` 经典的"长驻写入方留下旧偏移量、生成空洞文件"缺陷在这里不存在：`>>` 以 `O_APPEND` 打开文件，每次写入都落在当前文件末尾。

同一份规则也覆盖了 `s4hana_start.sh` 写的 `/var/log/s4hana_start.log`。
