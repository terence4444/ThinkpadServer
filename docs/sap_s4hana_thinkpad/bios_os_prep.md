# SAP S/4HANA Thinkpad BIOS 设定与操作系统预备

在将 Thinkpad（配有 192G 超大内存、独立显卡及双不同规格 SSD）部署为企业级 **SAP S/4HANA** 实验服务器时，硬件底层与操作系统的选型及安装配置至关重要。本篇汇总了特定的 BIOS 优化与 RHEL 10 部署避坑细节。

---

## 1. BIOS 专属优化配置

开机时按下 `F1` 进入 BIOS，根据 SAP 的高内存、高性能运行需求进行如下配置：

| 配置模块 | 配置项 | 推荐设定值 | 核心原因与目的 |
| :--- | :--- | :--- | :--- |
| **Security** | **Virtualization** | `Enabled` (开启) | 必须启用。为后续通过 KVM 虚拟机、Podman 容器或直接运行 S/4HANA 提供硬件级别的 CPU 虚拟化支持。 |
| **Devices** | **Intel VMD** | `Disabled` (禁用) | **重点**：配备的两块 SSD 规格、品牌各不相同，且不组建硬件 RAID。禁用 VMD（Volume Management Device）后，红帽 RHEL 系统可不加载特定 Intel 驱动直接原生地识别两块独立的 NVMe SSD。 |
| **Security** | **Absolute Persistence** | `Disabled` (禁用) | Computrace 固件级别的防盗追踪服务会向操作系统静默注入服务。将其彻底禁用，以确保核心企业级 SAP 系统的纯净度与安全度。 |
| **Security** | **Secure Boot** | `Disabled` (禁用) | RHEL 10 在加载未签名的第三方内核模块（如 NVIDIA 独显驱动、虚拟化驱动）时，若开启 Secure Boot 会因签名校验失败直接报错。由于服务器无安全启动签名需求，建议直接禁用。 |
| **Display** | **UMA Frame Buffer** | `忽略` | BIOS 中无此选项为正常现象。现代混合/独显架构能自动、动态地分配显存空间给显示设备，并不影响纯命令行下 SAP 服务器的内存调度。 |

---

## 2. 操作系统选型与安装参数 (RHEL 10)

### 2.1 FIPS Mode 安全合规设置
*   **推荐设定**: `Disabled` (关闭)
*   **避坑解析**: FIPS (联邦信息处理标准) 是极为严苛的系统级加密协议。**强烈建议在安装或配置 RHEL 时禁用 FIPS Mode**。若开启，会导致 SAP 的底层组件和特定高敏感密码库在运行过程中因严格的加密哈希校验出现报错、闪退，甚至带来不必要的系统运行损耗。

### 2.2 软件选择 (Software Selection)
*   **推荐设定（新机器）**: `Server`（不带 GUI）
*   **原因**: P16CHD 装完后从来没有用过图形界面。SWPM 是通过浏览器远程操作的，本机不需要 GUI；SAP 内核需要的少量 X11 相关包（如 `xorg-x11-xauth`）装系统后用 dnf 单独安装即可。P16EQ1 起按这个设定安装。
*   **P16CHD 的现状**: 安装的是 `Server with GUI`，当时的考虑如下（保留作为记录）：
*   **避坑解析**: 
    1.  **图形依赖库**: 虽然生产环境服务器不需要图形界面，但 SAP 安装器及 SAP 内核（Kernel）本身深度依赖大量的 **X11、GTK、图形渲染、中文字体与图形依赖包**。如果选择最小化安装 (Minimal Install)，后续补全图形开发包会非常繁琐。
    2.  **优雅调优 (装后切命令行)**: 安装完成后，通过以下命令将系统的默认启动级别切回到“纯命令行模式”（多用户模式），以节省 1~2G 的系统内存占用：
        ```bash
        # 将默认启动级别设为命令行
        sudo systemctl set-default multi-user.target
        ```

### 2.3 安装阶段“避坑”提示
*   **安装闪屏/花屏**: 
    若因独显驱动未就绪导致高分屏在安装引导界面出现闪烁、花屏甚至黑屏，请在启动 grub 引导菜单时：
    1.  选择 `Troubleshooting`。
    2.  点击进入 `Install Red Hat Enterprise Linux in basic graphics mode`（基础显卡模式安装）。
    3.  或者，在引导参数末尾手动追加键盘参数：`nomodeset`。

    ⚠ **装完后一定要去掉 `nomodeset`**：用 basic graphics mode 安装时，安装程序会把 `nomodeset` 永久写进启动参数。它会让 Intel 核显驱动（`i915`/`xe`）无法加载，结果 `/sys/class/backlight/` 是空的，背光脚本没有设备可控（P16EQ1 上就是这样）。检查并去掉：
    ```bash
    cat /proc/cmdline                                    # 有没有 nomodeset
    sudo grubby --update-kernel=ALL --remove-args=nomodeset
    sudo reboot
    ```
*   **用户创建**:
    在系统安装引导中，**可以不创建任何普通用户**，仅为 `root` 设置强密码即可。因为 SAP 安装程序（如 SWPM）在后续初始化部署时，会自动在操作系统的底层 and 用户组里创建其专属的运行账号（如 `hxadm`）。

---

## 3. RHEL 10 系统安装后的 SAP 专属依赖包与预配优化

在系统安装完成并顺利进入 RHEL 10 后，在正式运行 SAP S/4HANA 安装程序之前，必须配置 Red Hat SAP 专用通道并补全大量的依赖包。

### 3.1 激活 Red Hat SAP 解决方案订阅与软件源
SAP 专用的软件包（如 `compat-sap-c++` 或特殊的 `tuned` 配置文件）只能在红帽官方的 SAP 专有通道中获取，普通的 RHEL 订阅源不包含这些内容：

```bash
# 1. 注册并关联红帽订阅管理器
sudo subscription-manager register --username=your_username --password=your_password

# 2. 启用 RHEL 10 SAP Solutions 专用软件源
sudo subscription-manager repos --disable="*" \
  --enable="rhel-10-for-x86_64-baseos-rpms" \
  --enable="rhel-10-for-x86_64-appstream-rpms" \
  --enable="rhel-10-for-x86_64-sap-solutions-rpms" \
  --enable="rhel-10-for-x86_64-sap-netweaver-rpms"
```

### 3.2 补全 SAP S/4HANA 核心依赖包 (手配方案)
运行以下命令一次性补齐 SAP 安装所需的所有编译器兼容库、系统工具与挂载服务：

```bash
# 一键补全所有依赖包
sudo dnf install -y \
  compat-sap-c++-11 compat-sap-c++-12 \
  uuidd libnsl tcsh psmisc nfs-utils bind-utils \
  numactl libatomic libtool-ltdl xfsprogs libicu \
  expect graphviz iptraf-ng krb5-workstation \
  xorg-x11-xauth compat-openssl11
```
*💡 **重点说明**：由于 RHEL 10 默认内置 OpenSSL 3.0，而 SAP HANA 数据库目前依然硬性依赖 OpenSSL 1.1 的密码库，因此必须显式安装 `compat-openssl11` 包，否则数据库在部署时会直接发生动态链接库缺失闪退！*

### 3.3 激活 SAP 专属硬件性能调优服务 (Tuned-adm)
红帽为 SAP HANA 和 NetWeaver 应用层提供了专属的系统内核与性能调优策略（包括内存锁、空闲轮询、调度策略等）：

```bash
# 1. 确保 tuned 性能调优服务已启动并开机自启
sudo systemctl enable --now tuned

# 2. 根据服务器职责（数据库层 vs 应用层）激活对应的性能 Profile

# 若此 Thinkpad 做为 SAP HANA 数据库服务器：
sudo tuned-adm profile sap-hana

# 若此 Thinkpad 做为 S/4HANA 业务应用服务器：
sudo tuned-adm profile sap-netweaver

# 3. 验证当前生效的策略
tuned-adm active
```

### 3.4 推荐的高级自动化配置：RHEL System Roles for SAP
如果您希望完全避免手动调整各种复杂的 sysctl 内核参数、资源限制（limits.conf）和包依赖，可以使用红帽官方推荐的 Ansible 自动化预备包：

```bash
# 1. 安装官方提供的系统角色预配包
sudo dnf install -y rhel-system-roles-sap

# 2. 这会在 /usr/share/ansible/roles/ 下引入以下核心 Ansible Role：
#   - sap_general_preconfigure (自动配置基本系统、系统限幅、安装基础包)
#   - sap_hana_preconfigure (针对 SAP HANA 数据库的内核与参数极限优化)
#   - sap_netweaver_preconfigure (针对 SAP NetWeaver 架构应用层的配置)
```
