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

## 2. 关闭 Wi-Fi 省电（服务器用 Wi-Fi 时必须做）

能插网线就插网线。只能用 Wi-Fi 时，必须关掉 Wi-Fi 省电。NetworkManager 默认会打开省电（`iw dev <IF> get power_save` 显示 `on`），这时网卡大部分时间在睡眠，发给服务器的包要先在路由器上缓存，等下一个 beacon（约 100 ms）才送到。服务器自己往外 ping 看不出问题，但**别人访问服务器**时，每个包都可能多等几十到一百毫秒。

P16CHD 实测（2026-10-19，5 GHz，信号 -34 dBm，信号本身没有问题）：

| 测量 | 省电开 | 省电关 |
|---|---|---|
| 局域网 PC ping 服务器 | 23–112 ms，平均 59 ms | 2–4 ms，平均 3 ms |
| 经 VPN ping 服务器 | 平均 122 ms | 平均 47 ms |
| 经 VPN 取一个 UI5 静态文件（首字节） | 460–700 ms | 约 260 ms |
| 局域网取同一文件（首字节） | 60–130 ms | 28–48 ms |

### 排查

```bash
nmcli device status                       # Wi-Fi 接口名和连接名（连接名不是接口名，比如 ZDFLounge）
iw dev <IF> get power_save                # on = 开着省电
iw dev <IF> link                          # 信号、频段、速率
ping -c 50 -i 0.2 <路由器IP> | tail -2    # 服务器 → 路由器
```

最能说明问题的是**从另一台机器 ping 服务器**：局域网里应该是几毫秒，抖动很小。Windows 默认防火墙不回 ping，所以从服务器 ping Windows PC 不通是正常的。

### 关闭

```bash
# 立即生效，连接不断
iw dev <IF> set power_save off

# 永久：所有 Wi-Fi 连接默认关闭省电（下次连接时生效）
cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF
systemctl reload NetworkManager
```

`wifi.powersave` 的取值：`0` 默认，`1` 不管，`2` 关闭，`3` 打开。不要通过 Wi-Fi 上的 SSH 直接执行 `nmcli connection up`，会把自己断开。重启后用 `iw dev <IF> get power_save` 确认是 `off`。

**Debian 上提示 `iw: command not found`**：通常不是没装，而是 `iw` 在 `/usr/sbin`，普通用户的 PATH 里没有这个目录，加 `sudo` 就行（`sudo iw dev <IF> get power_save`）。

**真的没有 `iw` 时**：NetworkManager 的配置照样能写，只是没法马上生效，要等 Wi-Fi 重新连接。不想重启的话，可以让重连在后台执行，不依赖当前的 SSH 会话（Wi-Fi 会断几秒，IP 按 MAC 固定，所以不会变）：

```bash
CONN="$(nmcli -g GENERAL.CONNECTION device show <IF>)"; echo "$CONN"   # 只取连接名，比如 ZDFLounge
sudo systemd-run --on-active=5 nmcli connection up "$CONN"
sudo journalctl -u NetworkManager --since "-2min" | grep -i "<IF>.*activat"   # 10 秒后确认重连成功
```

注意：`nmcli -t -f NAME,DEVICE ...` 输出的是 `连接名:设备名`（比如 `ZDFLounge:wlp0s20f3`），不能整串当连接名用，否则 `connection up` 会失败，而且 `systemd-run` 在前台不会报错。

这时服务器上看不到省电状态，就从另一台机器 ping 服务器来验证。

### 可选：在驱动这一层关闭（Intel `iwlmvm`）

不管用不用 NetworkManager 都能用。先用 `lsmod | grep -E '^iwl(mvm|mld)'` 确认驱动是 `iwlmvm`。如果是 `iwlmld`（新的 Wi-Fi 7 驱动），这个参数不适用。

```bash
echo 'options iwlmvm power_scheme=1' | sudo tee /etc/modprobe.d/iwlmvm-no-powersave.conf
```

- `power_scheme` 的取值：`1` 一直醒着，`2` balanced（默认），`3` 最省电。
- 驱动加载时才读这个参数，所以要重启机器才生效。不要通过 SSH 重新加载 `iwlwifi` 模块，Wi-Fi 会断。
- 重启后用 `cat /sys/module/iwlmvm/parameters/power_scheme` 确认输出是 `1`。
- 有了上面 NetworkManager 的配置，这一步不是必须的，只是在驱动这一层再保一次险，代价是 Wi-Fi 多耗零点几瓦的电。

---

## 3. OpenVPN 自动拨号与 Systemd 服务集成

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