# ThinkPad 风扇控制（zcfan，fork 版本）

ThinkPad 的 EC（嵌入式控制器）默认自动控制风扇。在 P16 上，即使系统空闲、CPU 只有 40 多度，两个风扇也会以 2100 转左右持续运转，改 ACPI 平台模式（`performance` / `balanced`）也降不下来。要让空闲时风扇停转，需要由系统接管风扇控制。

---

## 1. 方案选择

| 方案 | 结论 |
| :--- | :--- |
| EC 自动控制（默认） | 最省心，但空闲时风扇一直在转 |
| EPEL 的官方 `zcfan`（cdown/zcfan 1.4.0） | **不用**：风扇会频繁启停 |
| **fork 版 `zcfan`（github.com/y1lichen/zcfan）** | **采用**：升温时马上升档，降档前有几秒延迟，避免频繁启停。P16CHD（2026-07）和 P16EQ1（2026-10）都在用 |
| thinkfan | 没有用过 |

温度高的时候（65°C 以上）把控制权交回 EC（`auto`），由 BIOS 按原厂曲线保护硬件。所以就算配置写得不好，也不会过热。

---

## 2. 配置

`/etc/modprobe.d/thinkpad_acpi.conf`（允许系统控制风扇）：
```
options thinkpad_acpi fan_control=1
```

`/etc/zcfan.conf`：
```
low_temp 50          # 低于 50°C：风扇停转
med_temp 65          # 50–65°C：low_level（1 档，最安静）
max_temp 75          # 65°C 以上：med_level / max_level = auto，交回 EC
temp_hysteresis 10   # 降档需要比触发温度低 10°C
max_level auto
med_level auto
low_level 1
```

启动时日志会打印每个温度对应的档位（`[CFG] At 50C fan is set to low` 等），之后每次切换都会记录（`[FAN] Temperature now 48C, fan set to off`）。

---

## 3. 安装

### 方式 A：从已经在用的机器拷贝（推荐，P16EQ1 就是这样装的）

两台机器的系统版本相同（RHEL 10.2）时，直接拷贝 P16CHD 上的程序，保证行为完全一致。P16CHD 上当初编译用的源码目录已经删了，以这个程序文件为准：

| 文件 | 说明 |
| :--- | :--- |
| `/usr/local/bin/zcfan` | SHA256 `d43695a2b52daca70f757db791ff787d9d1179f0ba7484db422ce37352d09f97`（2026-07-10 编译） |
| `/usr/local/lib/systemd/system/zcfan.service` | 主服务（WantedBy=default.target） |
| `/usr/local/lib/systemd/system/zcfan-sleep.service`、`zcfan-resume.service` | 休眠/唤醒用，服务器上不启用 |
| `/usr/local/share/man/man1/zcfan.1` | 手册 |
| `/etc/zcfan.conf`、`/etc/modprobe.d/thinkpad_acpi.conf` | 见第 2 节 |

```bash
# 在源机器上
tar -C / -cf zcfan.tar usr/local/bin/zcfan usr/local/lib/systemd/system/zcfan*.service \
    usr/local/share/man/man1/zcfan.1 etc/zcfan.conf etc/modprobe.d/thinkpad_acpi.conf
# 在目标机器上
sudo tar -C / -xf zcfan.tar --no-same-owner
sha256sum /usr/local/bin/zcfan
sudo systemctl daemon-reload
```

### 方式 B：从源码编译

```bash
sudo dnf install -y git gcc make
git clone https://github.com/y1lichen/zcfan.git
cd zcfan && make && sudo make install      # 装到 /usr/local
```
注意：fork 后来可能又有改动，编译出来的版本不一定和 P16CHD 上的一样。

### 启用

```bash
# fan_control=1 需要重新加载 thinkpad_acpi（或者重启）
sudo modprobe -r thinkpad_acpi && sudo modprobe thinkpad_acpi
cat /sys/module/thinkpad_acpi/parameters/fan_control      # Y
# 重新加载模块后，电池充电阈值要再写一次（见 power_battery.md）
sudo systemctl restart battery-charge-threshold.service
sudo systemctl enable --now zcfan.service
journalctl -u zcfan -f
cat /proc/acpi/ibm/fan                                       # level: 0 = 停转
```

⚠ **不要同时装 EPEL 的 `zcfan` 包**：它的服务文件在 `/usr/lib/systemd/system/zcfan.service`，虽然 `/usr/local` 下的优先级更高，但两个版本混在一起容易搞不清在跑哪一个。

⚠ **卸载 EPEL 的 `zcfan` 包时**：它的卸载脚本会执行 `systemd-update-helper remove-system-units zcfan.service`，因为服务**同名**，正在运行的 fork 版也会被停止、禁用。卸载后要马上重新启用（P16CHD 2026-10-17 就是这样做的）：
```bash
sudo dnf remove -y zcfan          # 只删 /usr/bin 和 /usr/lib 下的文件，/usr/local 不受影响
sudo systemctl daemon-reload && sudo systemctl enable --now zcfan.service
systemctl show -p FragmentPath zcfan.service    # 应该是 /usr/local/lib/systemd/system/zcfan.service
```

---

## 4. 已知现象

- HX 处理器负载一来，温度会瞬间冲到 80–90°C 以上，风扇随即升到最大（交回 EC），几秒后温度回落又降档。这是 CPU 温度的特性，fork 版的延迟已经让启停没有官方版那么频繁。
- 停用风扇控制：`sudo systemctl disable --now zcfan`，然后 `echo level auto | sudo tee /proc/acpi/ibm/fan` 把风扇交回 EC。
