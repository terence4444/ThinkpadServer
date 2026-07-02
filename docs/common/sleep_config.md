# 笔记本合盖休眠行为配置

在默认情况下，Linux 桌面版或服务器版系统在检测到笔记本合盖（Lid Close）时，会默认进入**挂起（Suspend）**或**休眠（Hibernate）**状态。对于服务器而言，必须将其配置为“合盖不休眠”。

---

## 1. 阻止合盖休眠的系统配置

systemd 使用 `logind` 服务来管理 ACPI 盖子开关事件。我们需要修改其全局配置文件。

### 配置步骤
1.  **编辑 systemd 登录配置文件**:
    ```bash
    sudo nano /etc/systemd/logind.conf
    ```
2.  **修改以下配置行**:
    寻找到以下参数，取消注释（去掉 `#`）并将其值设为 `ignore`：
    ```ini
    [Login]
    # 忽略合盖事件（外接电源和电池状态下均不休眠）
    HandleLidSwitch=ignore
    HandleLidSwitchExternalPower=ignore
    HandleLidSwitchDocked=ignore
    ```
3.  **保存并重启 `systemd-logind` 服务**:
    ```bash
    sudo systemctl restart systemd-logind
    ```

---

## 2. 避坑要点与硬件配合

*   **配置即时生效**: 重启服务后，合盖动作将不再触发任何休眠或挂起操作，系统和网络服务会持续在后台运行。
*   **物理屏幕缝隙 (重点建议)**: 即使配置了合盖不休眠，**也强烈不建议将笔记本盖子完全合死**。
    *   因为笔记本键盘区在服务器长期运行中是重要的辅助散热面，完全合盖会导致屏幕长期贴着高热量的键盘，易造成屏幕局部黄斑、老化甚至液晶变形。
    *   **最佳物理状态**: 保持约 **15° 的微张状态** 放置于防尘网格架上。
