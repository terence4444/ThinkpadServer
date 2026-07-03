# P16 + RHEL 10.2 + SAP HANA 自定义 Tuned Profile 记录

## 背景

当前系统：

- ThinkPad P16
- Intel Arrow Lake
- RHEL 10.2
- SAP S/4HANA Sandbox
- Tuned Profile：`sap-hana`

官方 SAP HANA Profile：

文件位置：

```text
/usr/lib/tuned/profiles/sap-hana/tuned.conf
```

内容：

```ini
[cpu]
force_latency=70
governor=performance
energy_perf_bias=performance
min_perf_pct=100
boost=1

[vm]
transparent_hugepages=madvise
dirty_bytes = 40%
dirty_background_bytes = 10%

[sysctl]
kernel.sem = 32000 1024000000 500 32000
kernel.numa_balancing = 0
vm.swappiness = 10
```

该配置适用于生产 SAP HANA 服务器，但对于笔记本开发环境较为激进：

- governor=performance
- energy_perf_bias=performance
- min_perf_pct=100

会导致 CPU 长时间保持高性能状态。

---

# 测试 Balanced Profile

切换到：

```bash

tuned-adm profile balanced

```

观察到：

```text
energy_performance_preference = balance_performance
min_perf_pct = 15
governor = powersave
boost = enabled
```

验证命令：

```bash

cpupower frequency-info
cat /sys/devices/system/cpu/intel_pstate/min_perf_pct
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference

```

结果：

```text
energy_performance_preference: balance_performance
min_perf_pct: 15
```

---

# 创建自定义 Profile

目标：

- 保留 SAP HANA 的 VM 和 SYSCTL 优化
- 使用更适合移动工作站的 CPU 策略

创建目录：

```bash

mkdir -p /etc/tuned/profiles/sap-hana-p16

```

创建配置：

```ini
# /etc/tuned/profiles/sap-hana-p16/tuned.conf

[main]
include=sap-hana

[cpu]
governor=performance
energy_perf_bias=normal
energy_performance_preference=balance_performance
min_perf_pct=15
boost=1
```

说明：

- 继承官方 `sap-hana`
- 保留 SAP HANA 调优参数
- 覆盖 CPU 部分设置

---

# 启用 Profile

```bash

tuned-adm profile sap-hana-p16

```

验证：

```bash

tuned-adm active

```

输出：

```text
Current active profile: sap-hana-p16
```

---

# 验证 SAP HANA 参数仍然生效

检查 Transparent Huge Pages：

```bash

cat /sys/kernel/mm/transparent_hugepage/enabled

```

期望：

```text
always [madvise] never
```

检查 Swappiness：

```bash

sysctl vm.swappiness

```

期望：

```text
vm.swappiness = 10
```

检查 NUMA Balancing：

```bash

sysctl kernel.numa_balancing

```

期望：

```text
kernel.numa_balancing = 0
```

检查 Semaphore：

```bash

sysctl kernel.sem

```

期望：

```text
kernel.sem = 32000 1024000000 500 32000
```

---

# 验证 CPU 覆盖生效

```bash

cpupower frequency-info

```

期望：

```text
energy performance preference: balance_performance
```

查看：

```bash

cat /sys/devices/system/cpu/intel_pstate/min_perf_pct

```

期望：

```text
15
```

说明 CPU 设置已经成功覆盖官方 SAP HANA Profile。

---

# 最终配置结论

当前推荐配置：

```text
Profile                     : sap-hana-p16
Governor                    : performance
Energy Performance Profile  : balance_performance
Energy Perf Bias            : normal
Min Perf Pct                : 15
Boost                       : enabled
```

效果：

- 保留 SAP HANA 优化
- 保留 Turbo Boost
- 空闲时可降频
- 发热更低
- 风扇更安静
- 适合 ThinkPad P16 上的 S/4HANA 开发/测试环境
