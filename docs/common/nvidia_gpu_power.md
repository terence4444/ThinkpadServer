# ThinkPad 移动工作站 NVIDIA 独显极致省电、降温与休眠配置

当搭载 NVIDIA 独立显卡的 ThinkPad 移动工作站（如 P16、P15、P1 等）被用作 7x24 小时运行的服务器时，独立显卡通常处于空闲状态。如果配置不当，独显不仅会消耗大量不必要的电量（造成“UPS”电池续航骤减），还会散发巨大的热量，导致风扇狂转、系统噪音大、缩短硬件寿命。

本篇介绍如何在无图形（multi-user.target）或混合显卡模式下，通过安装 NVIDIA 官方驱动、强制配置 Runtime D3 深度休眠参数、开启 PCIe 供电控制、以及彻底锁死唤醒服务，让独显在空闲时进入“零功耗物理休眠”状态。

---

## 1. 核心调优思路

1.  **安装官方驱动**: 弃用开源的 Nouveau 驱动（其电源管理支持极差），安装 NVIDIA 官方闭源驱动以获取底层的电源控制接口。
2.  **开启最深休眠 (Dynamic Power Management - 0x02)**: 强制驱动在显卡闲置时关闭 GPU 以及所有板载组件（包括 NV Link、存储器和传感器），将其置于 D3cold（最深休眠）状态。
3.  **允许内核切断 PCIe 供电**: 通过 `udev` 规则，允许操作系统内核对 NVIDIA GPU 进行 PCIe 链路层面的自动挂起（Auto Suspend）。
4.  **消除周期性唤醒源**: 停用并“锁死”（Mask）可能在后台周期性扫描总线或探测显卡拓扑的 NVIDIA 守护进程（如 `nvidia-persistenced`、`nvidia-powerd`），确保独显一旦休眠，就不会被意外唤醒。

---

## 2. 极致休眠与省电配置步骤

### 步骤 2.1：安装 NVIDIA 官方驱动
在 RHEL/Rocky Linux 环境下，建议通过 RPM Fusion 仓库或 NVIDIA 官方 CUDA 仓库安装官方专有驱动：
```bash
# 启用 EPEL 与 RPM Fusion 仓库
sudo dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm -y
sudo dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
sudo dnf clean all

# 安装 NVIDIA 官方驱动及内核模块
sudo dnf install -y nvidia-driver nvidia-settings
```
*(注：以上以 RHEL 9 为例，RHEL 10 或其他版本请替换对应的仓库源路径)*

---

### 步骤 2.2：配置驱动电源参数（进入 0x02 最深休眠）
我们要将 NVIDIA 驱动的动态电源管理级别设置为 `0x02`。该级别代表在闲置时不仅关闭显卡核心，还会关掉整块显卡的外围电路和显存供电。

在 `/etc/modprobe.d/` 目录下创建或写入配置文件 `nvidia-pm.conf`：
```bash
echo "options nvidia NVreg_DynamicPowerManagement=0x02" | sudo tee /etc/modprobe.d/nvidia-pm.conf
```

---

### 步骤 2.3：写入 PCIe 自动挂起规则（切断物理供电）
为了让 RHEL 内核可以对显卡进行 PCIe 链路级别的断电管理，我们需要创建一条自定义的 `udev` 规则：

使用 `nano` 或者是其他编辑器创建并编辑 `/etc/udev/rules.d/80-nvidia-pm.rules`：
```bash
sudo nano /etc/udev/rules.d/80-nvidia-pm.rules
```
将以下两行规则写入文件中并保存：
```udev
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", ATTR{power/control}="auto"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", ATTR{power/control}="auto"
```
> **原理说明**：这两个规则通过匹配 NVIDIA 的厂商 ID (`0x10de`) 和显卡类型（`0x030000` 表示 3D 控制器，`0x030200` 表示 3D 渲染控制器），将这些 PCI 设备的电源控制权（`power/control`）交由内核，设置为 `auto` 即可让内核在显卡空闲时自动挂起该 PCI 槽位的供电。

---

### 步骤 2.4：关闭并锁死 NVIDIA 监控服务（防止意外唤醒）
默认情况下，NVIDIA 安装的两个后台服务会为了“提升响应速度”或“监控拓扑”而周期性地向显卡发送探测信号，导致显卡刚睡着就被立刻唤醒。我们必须彻底停止、禁用并**锁死（Mask）**它们。

1.  **彻底锁死持久化服务 `nvidia-persistenced`**（该服务会让驱动保持常驻，阻止显卡休眠）：
    ```bash
    # 停止、禁用并锁死持久化服务
    sudo systemctl disable --now nvidia-persistenced.service
    sudo systemctl mask nvidia-persistenced.service
    ```
2.  **彻底锁死拓扑监控与功耗限制服务 `nvidia-powerd`**（该服务在笔记本上多用于动态调节 CPU/GPU 功耗分配，但其高频的总线探测是显卡休眠的头号杀手）：
    ```bash
    # 停止、禁用并锁死拓扑监控服务
    sudo systemctl disable --now nvidia-powerd.service
    sudo systemctl mask nvidia-powerd.service
    ```

---

## 3. 验证显卡休眠状态

完成配置并**重启系统**后，可以通过以下几种方式验证调优效果：

### 3.1 检查内核 Runtime 电源状态
通过读取 PCIe 设备的状态文件，可以直观确认显卡是否已在物理上挂起：
```bash
# 获取 NVIDIA 显卡的 PCI 地址（通常是 0000:01:00.0）
lspci | grep -i nvidia

# 查看其运行时的电源状态
cat /sys/bus/pci/devices/0000\:01\:00.0/power/runtime_status
```
*   **期望输出**：`suspended`（说明显卡已完全挂起，不消耗 PCIe 总线带宽和供电）。
*   若输出为 `active`，说明仍有进程或外接设备占用显卡，或者驱动未配置好。

### 3.2 观察物理温度与风扇
独显进入最深休眠（0x02 级别）后，你会发现：
1.  笔记本出风口温度显著下降。
2.  即使在高负载 CPU 编译时，风扇转速也会由于缺少了独显这个“发热大户”而变得极度克制，甚至在日常空闲时达到物理无声状态。

---

## 4. 与屏幕背光控制的联动

如果系统在 BIOS 中被配置为“仅独显模式（Discrete Graphics）”，或由于显卡没有加载电源管理，内核将无法找到主屏的背光控制设备（`/sys/class/backlight/` 目录下为空）。

若遇到此类找不到背光设备的情况：
1.  **显卡驱动修复**：先按照本篇指南完成 NVIDIA 官方专有驱动的部署和休眠优化。
2.  **切换为主屏 Intel 集显驱动**：在 BIOS 中，将 **Graphic Devices** 设置为 **`Hybrid Graphics`（混合显卡）**。此模式下，笔记本物理屏幕由高效、低功耗的 Intel 集显驱动，物理背光控制路径（`/sys/class/backlight/intel_backlight/`）会立刻显现，此时通过 [背光控制脚本](backlight_control.md) 即可完美控制屏幕亮灭。
