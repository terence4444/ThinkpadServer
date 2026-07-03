# P16 SAP HANA 开发机 - 已禁用服务

## 网络发现

### Avahi (mDNS / Bonjour)

适用于局域网自动发现服务。

SAP/HANA 开发环境无需使用。

```bash

systemctl disable --now avahi-daemon.service
systemctl disable --now avahi-daemon.socket

```

---

## 移动网络

### ModemManager

用于 4G/5G/LTE Modem 管理。

P16 未使用 WWAN 模块。

```bash

systemctl disable --now ModemManager.service

```

---

## 蓝牙

### Bluetooth

未使用蓝牙鼠标、键盘或耳机。

```bash

systemctl disable --now bluetooth.service

```

---

## Web 管理界面

### Cockpit

平时使用 SSH 管理。

采用按需启动模式。

禁用开机监听：

```bash

systemctl disable --now cockpit.socket

```

需要时启动：

```bash

systemctl start cockpit.socket

```

关闭：

```bash

systemctl stop cockpit.socket

```

訪问地址：

```text

https://hostname:9090

```

---

## SAN / iSCSI

当前系统只有本地 NVMe 存储：

```text

No active iSCSI session
No multipath device

```

### iSCSI

```bash

systemctl disable --now iscsi-onboot.service
systemctl disable --now iscsi-starter.service
systemctl disable --now iscsid.socket
systemctl disable --now iscsiuio.socket

```

### Multipath

```bash

systemctl disable --now multipathd.service

```

---

## 桌面音频实时调度

### RealtimeKit

无 GNOME / PipeWire / PulseAudio 使用场景。

```bash

systemctl disable --now rtkit-daemon.service

```

---

## 固件自动刷新

### fwupd 自动检查

保留 fwupd 工具。

关闭后台自动刷新：

```bash

systemctl disable --now fwupd-refresh.timer

```

