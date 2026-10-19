# PowerTop

**[English](README.md)** | **简体中文**

一个简洁轻量的菜单栏应用，实时显示你的 MacBook 正在消耗多少功率。

<p align="center">
  <img src="https://img.shields.io/badge/version-1.4.2-blue" />
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" />
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon-green" />
  <img src="https://img.shields.io/badge/license-MIT-orange" />
</p>

> **仅支持 MacBook** — 需要配备内置电池的 Apple Silicon MacBook。

## 终于能看到 MacBook 真实的功耗了

macOS 从来不会直接告诉你「现在系统正在消耗多少瓦」。PowerTop 解决了这个问题。

它把清晰、实时的功率信息放在菜单栏和弹窗里，让你随时知道电脑的用电情况。

## 主要功能

- **菜单栏电量显示** — 开启后在电池轮廓内显示电量数字（百分比），可与功率同时显示。低电量模式显示黄色，高电量模式显示白色，自动模式使用系统颜色；实际充电时在电池内的数字后显示小闪电。紧凑间距仅作用于 PowerTop。
- **电源模式切换** — 分别设置使用电池和连接电源时的自动、低电量、高电量模式；不支持高电量的设备会禁用该选项。
- **菜单栏功率显示（可选）** — 需要时可在菜单栏直接看到 `23W` 这样的实时数字。
- **功率流向图** — 一目了然地看到功率是来自充电器、电池，还是两者同时提供。
- **即时功率数据** — 系统功耗、充电器输出、电池充电或放电功率。
- **充电器负载情况** — 显示你的适配器功率以及当前使用率。
- **电池概览** — 快速查看电量、健康度、温度和循环次数。
- **预估剩余时间** — 在 Popover 和详细参数中估算可用时间；支持 macOS 充电上限（80/85/90/95%）及 AlDente 等第三方工具。
- **详细参数窗口** — 自动识别电芯拓扑（如 3S2P）、串联组电压、并联节电流、充电状态与生命周期统计。

数据实时更新，即使在插拔电源的瞬间也能保持准确可靠。

## 为什么用户喜欢用它

- 想知道 MacBook 实际消耗了多少功率
- 想了解自己的充电器在高负载时是否够用
- 想看到电池什么时候在帮忙供电
- 希望有一个简单漂亮的方式查看电池健康和充电行为

它是一个小巧的原生 Mac 应用，只做好一件事 —— 没有多余功能，没有订阅。

## 安装方式

### 下载安装（推荐）

从 [Releases](https://github.com/kDolphin/PowerTop/releases) 页面下载最新的 `PowerTop.zip`：

1. 解压文件
2. 把 `PowerTop.app` 拖到「应用程序」文件夹
3. 首次启动：右键点击应用 → **打开**（应用未签名）

### 从源码构建

```bash
git clone https://github.com/kDolphin/PowerTop.git
cd PowerTop
bash build.sh
open build/PowerTop.app
```

## 系统要求

- Apple Silicon MacBook（M 系列芯片）
- macOS 14（Sonoma）或更高版本

## 使用方法

1. 打开 PowerTop，图标会出现在菜单栏。
2. 点击图标即可看到功率流向图和当前各项数据。
3. 在弹窗底部开启「菜单栏显示功率」，即可让功率数值常驻菜单栏。
4. 在「电源模式」中分别设置使用电池和连接电源时的模式。在「菜单栏显示功率」下方展开「管理员权限授权」，点击「授权或修复权限」完成授权后，即可同时使用立即刷新和电源模式切换。两项操作共用一个后台服务，应用仍会重新读取系统设置确认模式切换结果。
5. 「菜单栏显示电量」默认开启，可与功率显示独立开关。
6. 点击「详细参数」可查看完整的功率和电池信息。

电源模式设置保存在系统中，不是充电上限。高电量模式取决于机型与系统支持。应用按设置的刷新间隔同步电源模式，以保持菜单栏颜色准确；后台读取不会禁用模式按钮，旧读数不会覆盖刚切换的模式；耗能应用列表只在面板打开时定期读取。默认每 2 秒读取功率；点击面板底部的间隔数值后，才能编辑 1–300 秒的刷新间隔。点击“应用”会在右侧显示“已应用”并退出编辑；取消或关闭面板会丢弃未应用的输入。也可点击右上角刷新按钮立即读取。插拔电源及唤醒时仍会额外刷新。

### 管理员权限授权

安装后的可选服务只接受本次授权的 PowerTop 应用签名和当前用户，只提供两项固定操作：电池/接电两种供电方式的三种电源模式切换，以及一次完整电池数据采样请求。采样请求不会改变充电、电源模式或系统轮询配置。它不接收任意命令，不保存密码，不修改 sudoers。服务文件位于 `/Library/PrivilegedHelperTools/com.kdolphin.PowerTop.EnergyHelper` 和 `/Library/LaunchDaemons/com.kdolphin.PowerTop.EnergyHelper.plist`，由 root 持有。点击「移除授权」可通过系统授权卸载。

当前是本地签名构建，更新或重新编译后签名会变化，需要再次点击「授权或修复权限」。授权前建议将应用放进「应用程序」。构建与测试不会安装此服务。

### 使用大量能耗的 App

读取 macOS 系统电池菜单使用的 `systemstats_get_top_coalitions` 数据源。已核对 macOS 26.6.2 控制中心的默认参数：120 秒窗口、最多 5 项、阈值 60000。列表不是实时 CPU 排名，也不是每个 App 的瓦数；后台子进程会尽量归并到负责它的 App。由于采样时机不同，列表可能与系统菜单短暂不同。

此只读接口未公开，未来系统版本可能变更。接口或返回格式不可用时会明确提示，不能将读取失败当作「没有使用大量能耗的 App」。列表只在面板打开时每 5 秒查询，手动刷新也会查询。点击列表或「打开活动监视器」可以查看系统详情。

功率来源统一按“有效系统功率读数 → 对应组件的电流 × 电压 → 其他独立功率做差估算”选择。电池优先 `BatteryPower`，其次为 `InstantAmperage × Voltage`、平均 `Amperage × Voltage`；充电器优先 `SystemPowerIn`，其次为 `SystemCurrentIn × SystemVoltageIn`。系统功耗优先读取有效的浮点瓦数 `BatteryData.SystemPower`，其次使用 `PowerTelemetryData.SystemLoad`，最后才做功率平衡估算。两项直接读数均保留相同的一致性检查。若电池读数表明正在充电，系统功耗却高于适配器输入，则拒绝该冲突读数；不能只回退电池功率，却继续保留不可能成立的系统功耗。整数形式的 `BatteryData.SystemPower` 单位不确定，不会直接使用。不会把充电器输入电压、电流算成系统自身功耗。有效零值会保留；两项数据缺失时不会互相循环推算，无法获得的值显示“—”。关系图的电池节点使用自身读数，不再复用系统节点。原始电池电流及 `BatteryPower` 的正数表示充电，负数表示放电，应用在读取时统一换算符号。充电时顶部和菜单栏瓦数是包含充电的适配器总输入。

定时刷新与「立即刷新」都通过管理员服务请求新采样，最多等待 10 秒，确认 UpdateTime 推进后再读取数据。手动刷新会等待正在进行的采样；定时任务遇到采样进行中则跳过，不堆积请求。休眠或停止监控会取消等待并暂停定时采样。修改间隔、插拔和唤醒通知仍只读取已有数据，避免采样触发通知后循环采样。失败时保留已有读数，并在刷新按钮显示错误。数值相同但时间戳更新仍算新采样；请求失败或超时会明确提示，显示已有读数而不冒充采样成功。

主动采样使用 macOS 私有电池驱动接口，设置的间隔不保证传感器每次都能及时更新。未授权时仍显示已有数据，并在刷新按钮提示采样错误。授权及移除操作的结果显示在「管理员权限授权」区域。

### 开发验证

`bash scripts/test-active-refresh.sh` 使用模拟请求验证定时和手动采样、请求合并、休眠及停止取消、超时、错误处理，以及普通读取不会调用管理员采样。签名应用的 `--configure-admin-service` 会申请管理员授权安装服务并验证一次采样；`--verify-active-refresh` 会检查已安装服务并请求一次真实采样。

`bash scripts/test-power-flow.sh` 验证充放电符号、真实补电、零电流、插拔过渡和功率回退计算；可添加 `--read-system` 只读对照本机。

`bash scripts/test-energy-modes.sh` 验证模式解析、失败和取消、百分比显示、刷新间隔保存与耗能数据解析；添加 `--read-system` 可只读核对本机数据。`bash scripts/test-integration.sh` 验证 XPC 签名准入、非法请求拒绝，以及真实状态栏开关后的弹窗定位。它们不安装服务，也不切换系统电源模式。实际管理员安装/卸载与切换需在 Mac 上手动验证。

## 截图展示

### 弹出窗口

| **AC 供电** | **电池放电** |
|-------------|---------------|
| <a href="screenshot/popover-ac-powered.png" target="_blank"><img src="screenshot/popover-ac-powered.png" width="260" alt="AC 供电"></a> | <a href="screenshot/popover-battery-discharging.png" target="_blank"><img src="screenshot/popover-battery-discharging.png" width="260" alt="电池放电"></a> |

| **AC 充电中** | **AC + 电池补充供电** |
|---------------|------------------------|
| <a href="screenshot/popover-ac-charging.png" target="_blank"><img src="screenshot/popover-ac-charging.png" width="260" alt="AC 充电中"></a> | <a href="screenshot/popover-ac-supplement.png" target="_blank"><img src="screenshot/popover-ac-supplement.png" width="260" alt="AC + 电池补充供电"></a> |

### 详细参数窗口

| **功率与电池健康** | **电芯数据** |
|---------------------|---------------|
| <a href="screenshot/detail-window-health.png" target="_blank"><img src="screenshot/detail-window-health.png" width="400" alt="功率与电池健康"></a> | <a href="screenshot/detail-window-cells.png" target="_blank"><img src="screenshot/detail-window-cells.png" width="400" alt="电芯拓扑与均衡"></a> |

## 更新内容

### v1.4.2

- **弹出框收回** — 点击空白处即可关闭面板（菜单栏应用在 macOS 15/26 上系统 `.transient` 经常不生效；issue #13）

### v1.4.1

- **菜单栏标签** — 改用系统状态栏按钮绘制功率数字，避免首次刷新后左右跳动，以及切换屏幕窗口时文字一直处于高亮

### v1.4.0

- **系统弹出框** — 菜单栏面板改用标准 `NSPopover`（圆角、材质、尺寸跟系统走），修复内容变高变矮时底色/圆角错位。

### v1.3.9

- **补电剩余时间** — AC + 电池补电时，自算放空时间只按电池实际放电功率，不再用整机功耗（感谢 @Collinw24，issue #12）

### v1.3.8

- **制造日期** — 从电池 pack 读取明确的 `ManufactureDate`（`YYYY-MM-DD`），不再把 `ManufacturerData` 当成周次（感谢 @Collinw24，PR #10 / issue #7）

### v1.3.7

- **AC 功率差判定** — 系统负载高于 AC 输入时，仅在电流或 BatteryPower 明确显示放电时才判为电池补电，不再单靠负载差推算补电功率（减轻遥测不同步时的误报；issue #8）

### v1.3.6

- **制造日期解析** — 优先按 `ManufacturerData` 长度前缀字段解析，并拒绝不合理的未来周次（避免部分机型出现如 2035 年第 14 周的错误显示；issue #7）

### v1.3.5

- **Popover 字号统一** — 电量/健康度行与其它指标行一致使用 12pt 系统字体（不再缩字、不再用 rounded 数字）

### v1.3.4

- **进度条对齐** — Popover 电量/健康度行使用固定标签列与图标，中英文下进度条起点一致
- **详细参数排版** — 概览与键值行统一固定标签/进度条列；窗口宽度调整为 480pt
- **电芯数据图标** — 改用兼容性更好的 SF Symbol，避免部分 macOS 版本图标缺失（感谢 @YangFong）

### v1.3.3

- **充电上限感知** — 预计充满时间按实际充电目标计算（macOS 设置、AlDente 或优化充电暂停点），不再一律按 100% 估算
- **更智能的上限检测** — AlDente Pro 开启「使用系统原生上限」时忽略旧配置；仅在优化充电暂停时才采用 `DailyMaxSoc`

### v1.3.2

- **电池健康修复** — 从 `BatteryData` 正确读取设计容量、满充电量与健康度；详细参数概览进度条对齐，容量命名更清晰
- **紧凑详细窗口** — 固定宽度以获得更紧凑的布局

### v1.3.1

- **电芯拓扑自动适配** — 从 IOKit 读取本机实际 S×P 结构（如 Air 的 2S2P、Pro 的 3S2P），不再写死某一种拓扑

### v1.3.0

- **预估剩余时间** — macOS 不再报告 `AvgTimeToEmpty` / `AvgTimeToFull` 时，根据剩余能量与平滑功耗自算放空/充满时间；Popover 与详细参数均可查看
- **电芯数据修复（Apple Silicon）** — 从 IOKit bank/cell 节点读取串联组电压/Qmax 与并联节电流，按本机实际拓扑自动适配
- **电芯均衡更清晰** — 拆分串联组电压均衡与并联节电流均衡
- **详细参数优化** — 修复重复行、制造日期移至设备信息、改进标签说明

### v1.2.0

- 详细参数窗口重设计、平铺布局、休眠唤醒后菜单栏即时刷新、0W idle 修复、电芯压差摘要

[更早版本 →](https://github.com/kDolphin/PowerTop/releases)

## 许可证

MIT 许可证。详见 [LICENSE](LICENSE)。
