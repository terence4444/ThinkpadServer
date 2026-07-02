# ClickHouse Thinkpad 磁盘分区与存储优化战略

在 Thinkpad (Debian 13) 上部署 ClickHouse 数据库服务器，其核心痛点是**高频次数据写入带来的磁盘寿命磨损**，以及**数据库崩溃风险（如 OOM / 磁盘爆满）**。

因此，我们采用 **2T 独占 SSD 物理隔离分区** 和 **高写入优化挂载参数** 的战略。

---

## 1. 2T SSD 物理隔离分区设计 (Debian 13)

为保证数据库的高可用及数据完整性，不建议采用一整块大分区的默认方案，而应进行职责划分：

| 挂载点 | 分配大小 | 文件系统 | 优化与防护战略 |
| :--- | :--- | :--- | :--- |
| **`/boot/efi`** | 1 GB | FAT32 | 自动预留充足引导空间。防止未来因多次自动升级 Linux 内核而导致引导区空间爆满（Debian 默认分配过小，极易踩坑）。 |
| **`swap`** | 8 GB | swap | **拒绝系统默认分配 25GB 的超大浪费**。保留 8GB 充当物理“安全气囊”，并配置 `swappiness=10`（仅当物理内存极度紧张时才使用 swap），防止因 ClickHouse 突发查询导致 OOM 崩溃。 |
| **`/` (系统根分区)** | 100 GB | ext4 | 仅用于系统基础组件、运行环境、系统日志与基础服务，实现系统与核心数据的物理级隔离。 |
| **`/data` (核心数据)** | 剩余全部 (1.8T+) | ext4 | **ClickHouse 核心主战场**。存放数据库的所有 MergeTree 数据块 and 临时缓存，保护系统不受数据库撑爆的影响。 |

---

## 2. `/data` 专属数据分区的写入与安全优化

为榨干 SSD 性能并最大化保护固态硬盘寿命，在 `/etc/fstab` 中挂载 `/data` 时，需追加多项专属参数：

### 挂载参数详解
*   **`noatime,nodiratime` (生命守护者)**: 
    默认情况下，Linux 每次读取文件都会向磁盘写入“最后访问时间”。ClickHouse 包含数以万计的小数据块，高频读取会带来海量的无用写入。开启此选项后，**全盘不再记录文件和目录的访问时间**，最大化保护 SSD 闪存寿命，并加速 ClickHouse 的并发写入。
*   **`nodev,nosuid` (安全防护)**:
    限制在此分区中创建字符或块设备文件（`nodev`），并禁用 SUID 执行权限（`nosuid`），从根本上防范越权提权攻击。

### `/etc/fstab` 配置实例

```text
# /etc/fstab 示例
UUID=xxxx-xxxx-xxxx-xxxx  /      ext4  defaults  0  1
UUID=yyyy-yyyy-yyyy-yyyy  /data  ext4  defaults,noatime,nodiratime,nodev,nosuid  0  2
```

---

## 3. 内核 swappiness 调优

为了避免系统频繁将 ClickHouse 内存页交换到 swap 中导致查询性能暴跌，需要将交换灵敏度降低：

1.  **临时生效**:
    ```bash
    sudo sysctl vm.swappiness=10
    ```
2.  **永久生效**:
    编辑 `/etc/sysctl.conf` 并加入：
    ```ini
    vm.swappiness=10
    ```
