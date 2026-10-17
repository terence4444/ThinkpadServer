# BIOS 通用安全与降耗配置

在将 ThinkPad 笔记本改造成 7x24 小时运行的服务器时，建议通过调整 BIOS 配置以兼顾系统底层的安全性、纯净度及整机功耗。

---

## 1. BIOS 安全与降耗核心配置表

在开机按下 `F1` 进入 BIOS，建议调整以下配置以兼顾安全性、纯净度及功耗：

| 配置项 (BIOS Section) | 推荐设定 | 核心目的与原理解析 |
| :--- | :--- | :--- |
| **Memory Protection (DEP)** | `Enabled` | 硬件级防缓冲区溢出攻击，提高操作系统底层的安全防御能力。 |
| **Intel PTT (TPM 2.0)** | `Enabled` | 启用硬件级安全密钥存储。便于后续如果需要对磁盘进行全盘加密（LUKS）时实现自动安全解密。 |
| **Virtualization (VT-x / VT-d)** | `Enabled` | 开启 CPU 硬件级虚拟化，为后续运行 Docker、KVM 虚拟机、SAP 环境或 K8s 提供必要支持。 |
| **Absolute Persistence** | `Disabled` | 彻底禁用 Computrace 防盗跟踪模块在后台向 Linux 系统静默注入服务，确保操作系统的纯净度与绝对控制权。 |
| **Wireless/Bluetooth/Camera/Fingerprint** | `Disabled` | 在 `I/O Port Access` 中，**关闭所有闲置硬件**（如蓝牙、摄像头、指纹识别、读卡器等）。彻底切断无用组件的供电，可降低 0.5W~1.5W 的待机功耗，同时减少发热。 |

| **Windows UEFI Firmware Update** | `Enabled` | 打开 UEFI 固件胶囊更新。不开的话，Linux 下的 `fwupdmgr` 只会提示 “UEFI capsule updates not available or enabled in firmware setup”，看不到也更新不了 BIOS/EC。打开后用 `fwupdmgr refresh && fwupdmgr get-updates` 检查。注意：LVFS 不一定有联想发布的每个 BIOS 版本，偶尔还要到联想支持网站按机型代码核对。 |

> **注 (配备独立显卡的机型说明)**:
> 对于配备独立显卡（如 NVIDIA 等）的机型，通常还需要在 BIOS 中禁用 **Secure Boot** (`Disabled`)，以防止 Linux 系统在加载未签名的 NVIDIA 独显驱动或第三方内核模块时出现签名报错。
