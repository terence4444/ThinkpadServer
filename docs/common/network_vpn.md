# ThinkPad 网络规范、OpenVPN 自动拨号与监控避坑

本篇介绍 ThinkPad 部署于局域网环境下的网络接入规范，以及在命令行无图形环境下实现 OpenVPN 自动安全拨号与系统监控的通用方案。

---

## 1. 静态 IP 地址分配规范

### 推荐方案：路由器 DHCP 静态绑定 (DHCP Reservation)
*   **做法**: 保持 ThinkPad 系统内置的 DHCP 动态获取设置，直接登录主路由器/网关后台，根据网卡的 MAC 地址进行静态 IP 绑定。
*   **核心原因**: 
    1.  **规避冲突**: 避免在笔记本本地直接修改 `/etc/network/interfaces` 或 `NetworkManager` 导致静态 IP 被局域网内其他设备意外占用或 IP 冲突。
    2.  **统一维护**: 集中在网关端管理所有服务器的 IP 分配，方便后续统一配置 DNS、网关或端口转发。

---

## 2. OpenVPN 自动拨号与 Systemd 服务集成

当服务器需要加入公司内网或异地组网时，我们需要通过 OpenVPN 在后台自动拨号，并挂载 `tun0` 虚拟网卡。

### 🚨 核心踩坑点: 超长配置文件名导致的 Systemd 转义报错
Systemd 服务启动 OpenVPN 时使用的是模版服务 `openvpn-client@<config_name>.service`。如果你的配置文件名含有特殊字符、点号（如 `my-company-prod-vpn-v2.1.ovpn`），Systemd 在转义参数时会发生严重报错，导致服务无法加载。

### 完美解决方案: 软链接统一命名法
我们无需更改原版超长的配置文件名，通过软链接将其链接到一个标准的、简单的文件名（如 `vpn.conf`）：

1.  **放置配置文件**:
    将你的 OpenVPN 配置文件放入 `/etc/openvpn/client/` 目录中。
2.  **创建标准软链接**:
    ```bash
    cd /etc/openvpn/client/
    # 假设原配置文件为 super-long-name-company.ovpn
    sudo ln -s super-long-name-company.ovpn vpn.conf
    ```
3.  **使用标准名称配置 Systemd 服务**:
    ```bash
    # 启用开机自动拨号 (自动加载 /etc/openvpn/client/vpn.conf)
    sudo systemctl enable openvpn-client@vpn
    
    # 立即启动拨号
    sudo systemctl start openvpn-client@vpn
    ```
4.  **验证状态**:
    ```bash
    # 检查服务运行状态
    sudo systemctl status openvpn-client@vpn
    
    # 验证是否成功挂载虚拟网卡 tun0 并获取到内网 IP
    ip addr show tun0
    ```

---