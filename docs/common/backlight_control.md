# ThinkPad 智能控光与物理快捷键开关屏方案

当笔记本被放置在货架上作为服务器运行时，其物理屏幕是不需要常亮的。在纯字符命令行（无 X11 / Wayland 桌面环境）下，直接修改 `/usr/local/bin/` 脚本控制背光，并监听物理按键是最稳定、最高效的实现方式。

---

## 1. 硬件控光原理

通过向系统的 ACPI 背光子系统直接写入数值，可以完美控制屏幕的亮度。
根据 ThinkPad 的配置，其背光设备路径通常为：`/sys/class/backlight/intel_backlight/` （Intel 平台）或 `/sys/class/backlight/amdgpu_bl0/` （AMD 平台）。本文以通用路径或自动检测方式为例。

*   **完全切断背光 (0W功耗/0发热)**:
    普通的屏幕保护程序只是把屏幕画成全黑，但 LCD 背光灯管依然在发光。直接往系统的 `brightness` 写入 `0`，可彻底关闭 LED 背光，达到物理黑屏状态。

---

## 2. 核心控制脚本

这两个控制脚本已独立存放在本仓库中，内部已配有详细的英文注释和限幅保护：

*   👉 **[一键物理闭屏脚本：scripts/common/backlight_off.sh](../../scripts/common/backlight_off.sh)**
*   👉 **[智能开屏调光脚本：scripts/common/backlight_on.sh](../../scripts/common/backlight_on.sh)**

### 2.3 部署脚本与赋权

你可以直接将这些脚本复制到服务器的 `/usr/local/bin/` 目录下并赋予执行权限：

```bash
# 从仓库复制脚本至系统可执行文件路径
sudo cp scripts/common/backlight_off.sh /usr/local/bin/backlight_off.sh
sudo cp scripts/common/backlight_on.sh /usr/local/bin/backlight_on.sh

# 赋予执行权限
sudo chmod +x /usr/local/bin/backlight_off.sh
sudo chmod +x /usr/local/bin/backlight_on.sh
```

---

## 3. 关联 ThinkPad 物理快捷键 (acpid 守护进程)

在纯字符命令行（无桌面）下，如何通过笔记本键盘的 `Fn + F4` (闭麦) / `Fn + F5` (亮度减/加) 等物理快捷键来直接控制开关屏？我们使用 Linux 的 **ACPI 守护进程 (acpid)**。

### 3.1 安装 acpid
```bash
sudo apt update && sudo apt install acpid -y
sudo systemctl enable --now acpid
```

### 3.2 捕获物理按键事件 (Event)
运行 `acpi_listen` 命令行工具，然后按下你想要绑定的物理快捷键。终端会输出对应的事件代码。例如：
*   按下 `Fn + F4` 可能会输出: `button/mute MUTE 00000080 00000000 K`
*   按下 `Fn + F5` (或背光按键) 可能会输出: `video/brightnessdown BRTDN 00000087 00000000 K`

### 3.3 编写 ACPID 事件映射规则

根据捕获到的事件代码，我们在 `/etc/acpi/events/` 中编写配置文件。

#### 1) 配置一键闭屏事件 `/etc/acpi/events/screen_off`
```ini
event=button/mute MUTE.*
action=/usr/local/bin/backlight_off.sh
```

#### 2) 配置一键亮屏与调光事件 `/etc/acpi/events/screen_on`
```ini
event=video/brightnessdown BRTDN.*
action=/usr/local/bin/backlight_on.sh
```

### 3.4 启动与验证

1.  **重启 acpid 守护进程**:
    ```bash
    sudo systemctl restart acpid
    ```
2.  **测试物理按键**:
    拔掉外接显示器，合盖微开，当你需要现场排查系统时：
    *   按下 ThinkPad 的一键闭麦物理按键 (`Fn + F4`)，屏幕背光瞬间**完全熄灭**。
    *   按下亮度调小键 (`Fn + F5`)，屏幕**立即唤醒**，多次按还可以增加亮度。
    *   完美实现了类似于服务器物理冷屏开关的效果！
