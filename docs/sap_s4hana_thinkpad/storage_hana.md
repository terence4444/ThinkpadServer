# SAP S/4HANA Thinkpad 存储分区与双 SSD 动态存储战略

对于拥有 **192G 超大内存** 和 **双物理 SSD** 的 Thinkpad 而言，传统的磁盘分区方案无法满足 SAP 数据库（SAP HANA）的极致 I/O 性能和高可用需求。

本方案采用 **双 SSD 职责隔离、大 Swap 防护与 LVM 动态逻辑卷** 组合的部署策略。

---

## 1. 物理磁盘职责划分

*   **第一块 SSD (系统盘)**: 负责安装 RHEL 10 操作系统、内核库文件、基本的 swap 交换区以及 `/` 根目录。
*   **第二块 SSD (数据盘)**: 独立于第一块盘。在操作系统安装期间**完全留空不进行分区**。安装完成后，将其整体作为 LVM (物理卷/卷组)，专职挂载给 SAP HANA 数据库主存储区（如 `/hana/data`、`/hana/shared` 等）。

---

## 2. 第一块 SSD 分区方案 (安装阶段)

建议严格按照以下顺序在 RHEL 图形化安装程序中手动创建分区。**绝不推荐一键自动分区**：

| 分区名 | 挂载点 | 分区类型 | 推荐大小 | 核心原因与设计理念 |
| :--- | :--- | :--- | :--- | :--- |
| **EFI 引导** | `/boot/efi` | Standard Partition | `500 MB` | 标准 EFI 系统引导区。必须作为**标准分区**创建，绝不能放入 LVM 卷组。 |
| **Boot 分区** | `/boot` | Standard Partition | `1 GB` | 系统内核及启动镜像存放区。同样必须作为**标准分区**创建，确保系统引导加载器 (Grub) 在底层可以直接寻址，引导更稳定。 |
| **Swap 交换区** | `swap` | LVM | `64 GB` | **核心调优**：在 RHEL+SAP 规范中，虽然物理内存高达 192G，但 SAP 官方仍强制要求配备高配 Swap。分配 64G Swap 能防止超大型数据在并行加载时把物理内存瞬时吃满。 |
| **根分区** | `/` | LVM | `剩余全部` | 操作系统、系统日志和 SAP 安装暂存盘。 |

> 💡 **操作避坑指南**:
> 推荐在 LVM 的同一个卷组（Volume Group，如 `vg_system`）下，同时划分 `swap` 逻辑卷和 `/` 逻辑卷。分区创建顺序建议为：`/boot/efi` ➔ `/boot` ➔ `swap` (指定 64G) ➔ `/`（不填写大小，让其自动吞掉第一块 SSD 的剩余所有空间）。

---

## 3. 第二块 SSD 分区与 HANA 专属卷挂载 (系统装好后)

第一块盘安装完成并进入系统后，我们再利用 Linux 逻辑卷管理器（LVM）对第二块专属 SSD 实施规划。这样可以根据 SAP 规范灵活调整 `/hana/data`（数据区）、`/hana/log`（日志区）和 `/usr/sap` 的空间配比。

### 3.1 创建物理卷与卷组
假设第二块 SSD 在系统中的设备名为 `/dev/nvme1n1`：
```bash
# 1. 将第二块 SSD 初始化为物理卷 (PV)
sudo pvcreate /dev/nvme1n1

# 2. 创建专属于 SAP 的卷组 (VG), 命名为 vg_hana
sudo vgcreate vg_hana /dev/nvme1n1
```

### 3.2 灵活划分 LVM 逻辑卷 (LV)
根据 SAP S/4HANA 的空间标准推荐（可根据实际 2T SSD 大小等比调配）：
*   `/hana/data`: 用于存放 HANA 内存数据库持久化到磁盘的数据页（建议分配 60% 空间）。
*   `/hana/log`: 用于存放 HANA 高频次事务日志（建议分配 20% 空间，日志读写需要极高性能）。
*   `/usr/sap` & `/hana/shared`: 存放 SAP 的应用程序内核及共享文件。

```bash
# 创建逻辑卷示例 (假设 vg_hana 总空间为 1.8T)
# 创建 1000G 用于数据
sudo lvcreate -L 1000G -n lv_hana_data vg_hana

# 创建 300G 用于日志
sudo lvcreate -L 300G -n lv_hana_log vg_hana

# 创建 300G 用于应用程序
sudo lvcreate -L 300G -n lv_hana_shared vg_hana
```

### 3.3 格式化与写入挂载表
由于 HANA 数据存储需要最高性能 and 低延迟，推荐采用 **XFS** 格式，并挂载：

```bash
# 格式化为 XFS
sudo mkfs.xfs /dev/vg_hana/lv_hana_data
sudo mkfs.xfs /dev/vg_hana/lv_hana_log
sudo mkfs.xfs /dev/vg_hana/lv_hana_shared

# 创建系统挂载点
sudo mkdir -p /hana/data /hana/log /hana/shared

# 编辑 /etc/fstab 写入挂载配置使其开机自启
# 追加以下内容:
/dev/mapper/vg_hana-lv_hana_data    /hana/data    xfs    defaults,noatime    0 0
/dev/mapper/vg_hana-lv_hana_log     /hana/log     xfs    defaults,noatime    0 0
/dev/mapper/vg_hana-lv_hana_shared  /hana/shared  xfs    defaults,noatime    0 0

# 执行挂载
sudo mount -a
```
*(通过加入 `noatime` 选项，可大大降低不必要的磁盘元数据写操作，提高 HANA 持久化的吞吐量。)*
