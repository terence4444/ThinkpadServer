# 双 SSD 磁盘分工原则（DRAM 盘 vs 无 DRAM 盘）

ThinkPad 服务器经常是两块盘：笔记本自带的一块，加上自己装的一块大容量盘。两块盘的写入性能可能差别很大，分区前先确认哪块盘带 DRAM 缓存，再决定什么放在哪里。

---

## 1. 原则

| 盘 | 特点 | 放什么 |
| :--- | :--- | :--- |
| **无 DRAM 缓存的盘**（通常是笔记本出厂自带的盘） | 持续写入和随机小块写入的性能差，SLC 缓存用完后速度会骤降；写入多了寿命也短 | **只放 OS**：`/boot/efi`、`/boot`、`/`、`/home`。可以再放**备份**：备份是顺序写入、次数少，而且和数据盘物理分开，数据盘坏了备份还在 |
| **带 DRAM 缓存的盘** | 写入性能稳定 | **所有经常写的东西**：数据库的数据和日志、数据库的运行目录和诊断文件、应用的工作目录（日志、trace）、传输目录、**swap** |

判断标准很简单：**这个目录在系统运行时会不会持续写入？** 会的话就放 DRAM 盘。

---

## 2. 怎么判断盘有没有 DRAM

最可靠的是查型号的规格表。也可以在 Linux 下看盘是否使用 HMB（Host Memory Buffer）。无 DRAM 的 NVMe 盘通常借用主机内存来代替 DRAM 缓存：

```bash
dnf install -y nvme-cli          # Debian/Ubuntu：apt install -y nvme-cli
nvme list                        # 型号、容量
nvme id-ctrl /dev/nvme0 | grep -iE "^(mn|hmpre|hmmin)"
nvme id-ctrl /dev/nvme1 | grep -iE "^(mn|hmpre|hmmin)"
```

- `hmpre` **不为 0**：盘支持 HMB，**基本可以确定是无 DRAM 的盘**。
- `hmpre` 为 0：通常是带 DRAM 的盘。最好再用型号核对一下规格。

---

## 3. 安装时的做法

1. 安装程序里**只处理 OS 盘**（无 DRAM 的盘），只建 `/boot/efi`、`/boot`、`/`、`/home`，用普通 LVM（不要用 Thin Provisioning）。卷组的剩余空间留着，以后放备份。
2. **数据盘（DRAM 盘）在安装程序里不要勾选。** 装完系统后再用 `parted` + LVM 建卷组和各个逻辑卷，见 [SAP HANA 的存储方案](../sap_s4hana_thinkpad/storage_hana.md) 第 3 节。
3. swap 也建在数据盘的卷组里。安装程序会提示没有 swap，确认跳过即可。
4. **数据库的数据卷最后创建**，让卷组的空余空间紧接在它后面，以后可以连续扩容：`lvextend -r -L +200G vg_sap/lv_sapdata`（`-r` 会同时扩大 xfs）。
5. 挂载参数：所有分区至少加 `noatime,nodiratime`；数据库数据卷参照 CHD 用 `noatime,logbsize=256k,allocsize=64m`。
6. 备份目录如果放在 OS 盘的 `/` 上，又要出现在数据盘的挂载点下面（例如 `/sapdb/backup_archive`），就在 `/` 上建实际目录，再用 **bind mount** 挂过去。⚠ 不能在 `/sapdb` 挂载后直接 `mkdir`，那样目录会落在数据盘上。
7. 装完**重启一次**，确认 fstab 里的所有挂载都能在开机时自动生效。

---

## 4. 实例：P16EQ1（SAP NetWeaver ABAP + MaxDB，96 GB 内存）

两块盘：SK Hynix HFS512GEM9X169N（512 GB，`hmpre=16384`，**无 DRAM**）、KIOXIA EXCERIA PRO G2（1.9 TB，`hmpre=0`，**带 DRAM**）。

**512 GB 自带盘（无 DRAM）**，卷组 `rhel_saperp`（安装程序建的，实际执行时没有按计划拆分出 `/home`）：

| 挂载点 | 大小 |
| :--- | :--- |
| `/boot/efi` | 1 GB（标准分区） |
| `/boot` | 2 GB（标准分区） |
| `/` | 470 GB |
| `/backup/sapdb_archive` → bind mount → `/sapdb/backup_archive` | `/` 上的目录（备份） |

**2 TB 盘（带 DRAM）**，卷组 `vg_sap`，按下表顺序创建：

| 顺序 | 挂载点 | 大小 | 写入内容 |
| :--- | :--- | :--- | :--- |
| 1 | `/usr/sap` | 50 GB | work 目录、trace |
| 2 | `/usr/sap/trans` | 100 GB | 传输导入 |
| 3 | `/sapmnt` | 30 GB | 作业日志、spool |
| 4 | `/sapdb` | 50 GB | MaxDB 运行目录、诊断文件 |
| 5 | `/sapdb/DB1/saplog` | 20 GB | 日志卷 |
| 6 | swap | 32 GB | |
| 7 | `/sapdb/DB1/sapdata` | 800 GB | 数据卷，**最后创建** |
| — | 不分配 | 约 825 GB | 紧接在数据卷后面，留给扩容 |

> 对比：P16CHD 的系统盘是 953.9 GB、数据盘是 1.8 TB，`/usr/sap`、`/sapmnt` 放在系统盘的 `/` 上（见 [storage_hana.md](../sap_s4hana_thinkpad/storage_hana.md)）。这是 CHD 的现状，没有按本原则调整。
