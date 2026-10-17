# 💻 Thinkpad 生产级服务器化改造指南 (Thinkpad Server Setup)

欢迎来到 **Thinkpad 服务器化改造 (ThinkpadServer)** 知识库！本项目系统地整理了将联想 Thinkpad 笔记本完美改造成冷静、安全、高可用生产级 Linux 模拟服务器的全套实践方案。

笔记本做服务器具有**自带“UPS”（电池）**、**超低功耗**、**集成屏幕/键盘便于现场排查**等得天独厚的物理优势，只要配置得当，就能成为极佳的微型服务器。

---

## 🛠️ 改造场景一览

项目包含两种截然不同的典型企业级服务部署实战方案：
1.  **极速高并发写入数据库方案**: 基于 **Thinkpad** + **Debian 13** 搭建的 **ClickHouse** 列式存储服务器。
2.  **超大物理内存高负载环境方案**: 基于 **Thinkpad (192G 内存 + 独显 + 双 SSD)** + **RHEL 10** 搭建的 **SAP S/4HANA** 实验服务器。

---

## 📚 知识库目录结构

我们对通用的物理/底层硬件设置，以及特化的系统/应用配置进行了结构化提取，您可以点击链接直接跳转查阅：

### 🔄 第一部分：通用底层改造方案 (Common Setup)
本部分适用于**所有**使用 Thinkpad 笔记本做服务器的场景，解决了硬件保护、供电防灾、控光、网络及合盖控制的核心痛点。

*   **[BIOS 通用安全与降耗配置](docs/common/bios_hardware.md)**
    *   Memory Protection (DEP)、Intel PTT 安全加固、无用外设 (蓝牙/指纹/摄像头) 彻底断电降耗
*   **[双 SSD 磁盘分工原则 (DRAM 盘 vs 无 DRAM 盘)](docs/common/disk_layout.md)**
    *   无 DRAM 的自带盘只放 OS 和备份，数据库、应用工作目录、传输目录、swap 等经常写的内容全部放 DRAM 盘
    *   用 `nvme id-ctrl` 的 HMB 字段判断盘有没有 DRAM，安装时只处理 OS 盘
*   **[电池保护 (TLP) 与停电 40% 模块化优雅关机](docs/common/power_battery.md)**
    *   TLP 充电上限配置 (开始 58%，结束 64%)，写入主板 EC，彻底防止电池鼓包；RHEL 10 没有 TLP 时用 systemd 服务写 sysfs
    *   轻量级 Bash 放电监控脚本，40% 电量以下自动触发关机倒计时，通过模块化钩子优雅停止 ClickHouse/SAP 等高负载应用
*   **[笔记本合盖休眠行为控制](docs/common/sleep_config.md)**
    *   修改 systemd `logind.conf`，配置合盖不挂起/不休眠
*   **[NVIDIA 独显极致省电、降温与休眠配置](docs/common/nvidia_gpu_power.md)**
    *   在无图形环境下部署 NVIDIA 官方专有驱动，配置 Runtime Power Management (`0x02` 级别最深休眠)
    *   写入 PCIe 自动挂起规则，完全切断空闲显卡的 PCIe 供电并锁死 (Mask) 唤醒服务
*   **[网络规范、OpenVPN 自动拨号与功耗 Bug 排查](docs/common/network_vpn.md)**
    *   路由器 DHCP 静态绑定规避 IP 冲突
    *   软链接解决 Systemd 在超长或特殊字符 OpenVPN 配置文件名下的转义报错
    *   `btop++` 功耗误报（把 50Wh 剩余容量识别为 50W 功耗）的解决方案与 Snap 自动更新
*   **[智能无桌面控光脚本与物理快捷键关联 (acpid)](docs/common/backlight_control.md)**
    *   一键物理熄屏脚本 (写入 0，实现 0 瓦功耗与 0 发热)
    *   智能开屏调光脚本 (一键唤醒、10% 步进、安全限幅)
    *   ACPI 守护进程映射，使纯字符终端支持 Fn 快捷键极速闭屏/开屏

---

### 🚀 第二部分：ClickHouse 专属服务器配置 (Thinkpad Debian 13)
针对高频写入的高性能列式数据库场景，侧重存储寿命与磁盘调优。

*   **[磁盘分区战略与 ext4 高吞吐挂载优化](docs/clickhouse_thinkpad/partition.md)**
    *   1GB 充足 UEFI 引导分区、8G 物理防 OOM 安全气囊 Swap 规划
    *   `/data` 数据盘 `noatime,nodiratime` 专属挂载参数，最大化保护 SSD 闪存寿命并加速 ClickHouse 写入
*   **[多用户 SSH 证书登录与 Sudo 权限安全管控](docs/clickhouse_thinkpad/ssh_cert_login.md)**
    *   基于 SSH 证书局域网 (CA) 的多用户无密码高安全级别登录设计
    *   本地 Sudo 权限的两类提权凭据模式 (独立 Unix 密码安全阻断 vs 免密高吞吐) 的权衡与配置
    *   服务器防越权提权、密钥丢失提前吊销 (KRL) 等核心避坑加固实践
*   **[沙盒开发系统崩溃快速恢复与灾备重建](docs/clickhouse_thinkpad/system_recovery.md)**
    *   基于 `/data` 物理隔离分区的系统凭证与用户 CA “秒级还原”机制
    *   ClickHouse 数据库的元数据/表结构极速导出与测试脏数据物理清洗
    *   宿主机坏死一键自动化 Bootstrap 重建脚本（网络挂载、调优、常用组件、内网防火墙一键配齐）
    *   网卡死机、磁盘爆满、Sudoers 写错锁提权等三大经典沙盒崩溃高频“应急三板斧”速查

---

### 🏆 第三部分：SAP S/4HANA 专属服务器配置 (Thinkpad RHEL 10)
针对 192G 超大内存、独显及双 SSD 异构环境，侧重系统纯净度、大内存下的逻辑卷设计，以及系统装完后的 SAP 专属依赖包补配。

*   **[BIOS 特定选项与操作系统预备 (RHEL 10)](docs/sap_s4hana_thinkpad/bios_os_prep.md)**
    *   禁用 Intel VMD 实现异构双 SSD 免驱直认
    *   禁用 Absolute Persistence (Computrace) 确保系统纯净
    *   禁用 Secure Boot 防止独显驱动与内核驱动签名报错
    *   禁用 FIPS Mode 规避 SAP 服务及密码库运行报错与损耗
    *   P16CHD 安装的是 `Server with GUI`，随后切换为 multi-user.target 字符界面；装完后从未用过 GUI，因此新机器直接安装 `Server`（不带 GUI）
    *   **一键补齐 SAP 核心依赖包 (如 compat-sap-c++、compat-openssl11 等) 与 Tuned 调优服务**
*   **[大内存 Swap 设计与双 SSD 动态 LVM 挂载方案](docs/sap_s4hana_thinkpad/storage_hana.md)**
    *   第一块盘手动建立 64GB 强力 Swap 逻辑卷与独立引导分区
    *   第二块盘完全作为独立 LVM 卷组 (`vg_hana`)，专职挂载至 `/hana/data`、`/hana/log` 等关键存储区
    *   数据卷格式化为高性能 XFS 文件系统，配置 `noatime` 降低持久化延迟

---

## 💡 总结与鸣谢

本方案由 **Gemini Enterprise** 与您共同深度打磨，经过长时间的底层摸底与线上实测，是一套技术成熟、实操性强的**笔记本物理服务器改造路线图**。

如果您在使用过程中有任何新的灵感、配置更新或遇到报错，欢迎在本项目中发起讨论！祝您的 Thinkpad “无声、冷静、稳定”地永久奔跑！💨
