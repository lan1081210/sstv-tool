# SSTV Tool for macOS (arm64)

一个 macOS 上的 SSTV 收发工具：**收**（解码电台/录音里的慢扫描电视信号，自动认模式）
和**发**（把一张图变成 SSTV 音频，喂给电台发出去）。

底子是 [SodaGray/apricot-sstv](https://github.com/SodaGray/apricot-sstv)（iPod nano 7 上的 SSTV 接收机）：

- 解码核心 `src/sstv_dsp.c` 原样搬过来，一行没动（GPL-3.0）：解调、VIS 检测、无 VIS 自动锁同步、
  斜率校正报 ppm、衰落/丢包续画都在。换掉的是采集层（CoreAudio AUHAL 代替 nano 的 DMA）、
  显示层（AppKit 代替 320×240 RAW surface）、保存层（ImageIO PNG 代替 BMP）。
- 发射侧用同一上游仓库里的 host 编码器 `tools/enc.c`（14 个模式的波形生成），
  外面套一层 macOS 的皮：任意图片格式进、保比例加黑边、可选文字叠加、存 WAV、直接播放。
  功能对齐 [olgamiller/SSTVEncoder2](https://github.com/olgamiller/SSTVEncoder2)（模式选择 / 保比例 /
  文字叠加 / 存 WAVE / 播放）。

## 收：自动识别，或者守着一种模式

窗口左下角有个「收:」下拉框：

- **收: 自动**（默认）——按 VIS 头认模式，14 种都收
- **收: PD120** 之类——只认这一种：VIS 是别的模式就当没听见；VIS 丢了也能靠行同步脉冲锁定。
  国际空间站那一轮、或者某个固定用 PD120 的台，整晚挂着不用管

命令行同一件事：`sstv-tool --listen --rx-mode pd120`（`--rx-mode auto` 恢复自动）。

**连续输出**（窗口里的「连续」勾选框，或 `--continuous`）：不等 VIS 头，一张解完立刻接着下一张。
勾上之后只要信号里有行同步就一直往下画——第一张靠同步脉冲起飞，后面的帧在前一帧结束的瞬间就
挂好队，下一帧的第一条同步脉冲一到就开画（帧间那段静音或重复的 VIS 最多丢一行）。
实测：一段完全没有 VIS、两帧首尾相接的 PD120，出两张完整图，中间没有空转。

```sh
sstv-tool --listen --rx-mode pd120 --continuous     # 守着 PD120，不等头，一直出图
```

适合信标台、固定模式的循环发射，或者你明知道对面用哪种模式、懒得等 VIS 的场合。

图存在 `~/Pictures/SSTV Tool/`（.app 的工作目录是 `/`，写不进去，所以默认放这儿；命令行版仍在当前目录或 `--out`）。

## 偏移是自动纠正的

窗口里没有模式下拉框，因为不需要：收到信号先读 VIS 头定模式（14 种全覆盖），
VIS 丢了（信号开头没抄到、被压掉）就退一步用行同步脉冲的周期和 sync 长度去匹配锁定。
一晚上换四五个模式、中途改模式都行，解完一张自动存图、立刻回到"听"，下一张按新 VIS 重新认。

`SSTV Tool --modes` 打印这个构建实际能解的模式（问解码器自己，不是写死的表）。
顺带一句：VIS 4（Robot 24）解码器认得名字但不解——上游也没实现，会显示 `Skip Robot 24`。

## 发：一张图变成 SSTV 音频

窗口里就能发（不用记命令行）：底部第二排是 **模式下拉框 + 「发图片并播放」+ 「存成 WAV」+ 「停止」**。

- 「发图片并播放」：选图 → 按下拉框里的模式生成 → 从系统默认输出放出来，右侧显示
  `正在发射 47% 剩 68 s 图名-模式.wav`，一条橙色进度条跟着走；「停止」随时掐断
- 「存成 WAV」：只生成文件，给你用别的播放器/发射机
- 生成的文件都存在 `~/Music/SSTV Tool/`（跟 SSTVEncoder2 存 Music 的习惯一致）
- 窗口里那排「暂停 / 取消这张」管的是**接收**，跟发射互不影响

命令行等价物（不带窗口，直接出 WAV；加 `--play` 就放出来）：

```sh
sstv-tool --send 图.png --mode pd120            # 开窗口发，带进度条
sstv-tool --send 图.png --mode pd50 --no-play   # 只生成，不播放
sstv-tool encode 图.png --mode m1 --play        # 纯命令行，无窗口
```

详细参数：

```sh
# 最基本：默认 Robot 36，输出 example-Robot36.wav 放在图旁边
sstv-tool encode example.jpg

# 指定模式（模式名、简写、VIS 号都行：pd120 / m1 / s2 / 95 / 44）
sstv-tool encode photo.png --mode pd120
sstv-tool encode photo.png --mode m1 --out ~/Desktop/m1.wav

# 文字叠加 + 直接播出来（电台对着喇叭就能发）
sstv-tool encode photo.png --mode pd50 --text "CQ CQ DE LAN" --play

# 保比例（默认 letterbox，加黑边）/ 裁切填满 / 拉伸
sstv-tool encode photo.png --fit letterbox
sstv-tool encode photo.png --fit fill

# 造一个"坏信号"给接收端做压力测试
sstv-tool encode photo.png --mode pd120 --ppm -400 --offset -40 --snr 18

sstv-tool encode --list-modes     # 能发哪些模式、各自画幅
```

其他参数：`--rate HZ` 采样率（默认 44100）、`--lead S` / `--tail S` 前后静音、
`--gain F` 幅度（0..1，默认 0.9）、`--no-wait` 播放时不等它放完。

发射和接收是同一套模式表，`make test` 里有一条 14 个模式逐个"编码→解码"的闭环自测。

## 支持的 14 个模式

| 模式 | VIS | 画幅 | 时长 | 解码 PNG 尺寸 |
|---|---|---|---|---|
| Robot 36 | 8 | 320×240 | 36 s | 320×240 |
| Robot 72 | 12 | 320×240 | 72 s | 320×240 |
| Martin M1 / M2 | 44 / 40 | 320×256 | 114 / 58 s | 320×256 |
| Scottie S1 / S2 / DX | 60 / 56 / 76 | 320×256 | 110 / 71 / 269 s | 320×256 |
| PD50 / PD90 | 93 / 99 | 320×256 | 50 / 90 s | 320×256 |
| PD120 | 95 | 640×496 | 126 s | 320×248（半尺寸） |
| PD160 | 98 | 512×400 | 161 s | 256×200（半尺寸） |
| PD180 / PD240 | 96 / 97 | 640×496 | 187 / 248 s | 320×248（半尺寸） |
| PD290 | 94 | 800×616 | 289 s | 400×308（半尺寸） |

宽于 400 px 的模式接收时按半尺寸存（上游的固定内存策略），每个像素取两倍宽度采样、
每 sync 的两行平均。`--scale 2` 可以让 PNG 存成两倍尺寸（最近邻放大，看着舒服但不加细节）。
发射侧是按模式的原始画幅编码的，不受这个限制。

## 编译

需要 Xcode Command Line Tools（clang）。arm64 原生，无第三方库。

```sh
make            # build/sstv-tool + build/SSTV Tool.app + 测试信号工具
make test       # 收发自测：14 模式解码 + 14 模式闭环 + 干扰信号 + 连收（35 项）
make test-pause # 暂停 / 取消按真实速度验证（约 90 秒）
sudo make install   # 装到 /usr/local/bin/sstv-tool（可选）
```

## 用法（收）

```sh
# 解一段录音（wav/aiff/m4a/flac/caf 都行，CoreAudio 能读的都能读）
sstv-tool ~/Desktop/sdr-2026-11-06.wav
# → 同目录下 sdr-2026-11-06-1.png、-2.png ...；录到一半的信号也会存一张

# 实时接收（电台/对讲机音频进线路输入或麦克风口）
sstv-tool --listen
sstv-tool --list                     # 先看设备编号
sstv-tool --listen --device 1        # 指定设备
sstv-tool --listen --no-view         # 不要窗口，日志 + 自动存图

# 把一个文件按真实速度走一遍实时链路（调窗口布局、验证录到的信号用）
sstv-tool --simulate recording.wav
```

常用参数：`--out DIR` 输出目录、`--prefix NAME` 文件名前缀、`--scale N` 放大存图、
`--no-autosync` 不听同步脉冲自动起图、`--ppm N` 给时钟误差先验、`--quiet` 静音模式。

窗口里：上方三行是状态（模式/行数、调谐 Hz 与偏移、时钟 ppm、同步 x/y、电平 dBFS、已存文件），
底下两条是电平表和调谐条（红区是 1500–2300 Hz 的 sync/porch 频段）。

收的过程里随时能打断：

| 操作 | 按钮 | 键盘 | 无窗口/脚本 |
|---|---|---|---|
| 暂停 / 继续 | 「暂停」→「继续」 | 空格 | `kill -USR1 <pid>` |
| 放弃正在收的这张 | 「取消这张」 | X | `kill -USR2 <pid>` |
| 退出 | 关窗口 | Q / Esc | Ctrl-C |

暂停时画面停住并变暗显示"已暂停"，音频照常在采（电平表还在动），只是不喂给解码器——
丢掉的样点按时间轴记账，所以恢复后不会整体歪斜：

- 暂停十秒上下以内：接着从原来那一行往下画，图能完整收到（中间那段是空的）
- 更长：解码器按"信号丢了"处理，这张图提前收尾存盘，下一个信号来了从头开始认模式
  （边界由解码器的 `LOST_S_VIS`=12 秒决定，实测 5 秒能续、12 秒就判丢）

「取消这张」= 放弃当前这张，已经解出来的部分照样存成 PNG（`image ended (aborted)`），然后回聆听。
空跑的时候取消键是灰的。`make test-pause` 把这两个动作按真实速度跑一遍（约 90 秒）。

## 装进"应用程序"和 Dock

```sh
make app && cp -R "build/SSTV Tool.app" /Applications/   # 装进应用程序（Launchpad 里就有）
open -a "/Applications/SSTV Tool.app"                    # 启动，直接进实时接收
```

`SSTV Tool.app` 是独立 TCC 身份，麦克风授权记在"SSTV Tool"名下（com.lan.sstv-tool）。
注意 ad-hoc 签名是按二进制哈希记的，**每次重新编译重装都会再问一次**麦克风权限，点"允许"即可；
命令行版跑在自己的终端名下，需要终端在 系统设置 → 隐私与安全性 → 麦克风 里被勾选。

Dock 常驻：`defaults write com.apple.dock persistent-apps -array-add '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file:///Applications/SSTV%20Tool.app/</string><key>_CFURLStringType</key><integer>15</integer></dict><key>file-label</key><string>SSTV Tool</string><key>file-type</key><integer>41</integer></dict><key>tile-type</key><string>file-tile</string></dict>' && killall Dock`

图标是 `assets/AppIcon-1024.png`（一张解出来的测试卡，圆角由 `tools/makeicon.c` 现切），
想换：`make icon SRC=别的图.png`。`assets/AppIcon.icns` 由 Makefile 用 sips + iconutil 生成。

频偏不用手动调：解码器从 VIS 前导（或者从同步脉冲本身）测出偏差、把整套判决门限跟着平移，
状态行那个 `偏移 -5 Hz` 就是它测到并已经补偿掉的量。本版把可接受的范围从上游的 ±150 Hz 放宽到
**±250 Hz**——电台表盘差两三百赫兹也能自己纠回来；再远就不是"偏移"，得重调频率了。
（这次放宽用上游自带的 66 项解码测试回归过，误锁（false start）仍然 0。）

## 默认"扫完整张才结束"

不再按"信号断了多久"判死：**帧一开始，就按这张图的时长一直扫到底**，中间没信号的那一段留白，
扫满 496 行（或该模式的长度）才收尾存图。中途回来也照样接上，不用手动干预。

```sh
sstv-tool rec.wav                 # 默认：扫完整张（0 超时）
sstv-tool rec.wav --lost 12       # 想要上游那种"12 秒没同步就放弃"的老行为
```

实测：PD120 中间挖掉 60 秒，仍然 496/496 扫完，上半彩条+灰阶正常、中间一条大空白带、
下半棋盘落在正确位置（时间轴没歪）。

一帧里同步命中少于 10% 的（基本是噪声凑出来的假帧）不存盘，日志写 `frame dropped`。

窗口第一行的结束原因：

| 显示 | 含义 | 处理 |
|---|---|---|
| `完成` | 整张扫完了 | 正常 |
| `中断·图已保留，等它回来对齐` | 只有指定了 `--lost` 才可能出现 | 图**没有丢**：信号回来自动对齐、从断的那一行接着画 |
| `被新信号打断` | 图中间误判出一个 VIS 头 | 噪声里的假 VIS；换干净的音频源或降噪 |
| `已取消` | 点了「取消这张」/ 发了 SIGUSR2 | —— |

丢样（机器卡顿、环形缓冲溢出）和信号衰落是两回事，程序分开处理：

- **丢样**走 `sstv_gap`，时间轴照样精确推进，解码器**不会中断这张图**，只是那一段的行不画。
  自测里挖 15 秒的洞，图照样 496/496 收完（`capture dropout PASS`）。
  程序用 `beginActivityWithOptions(NSActivityLatencyCritical)` 顶住 App Nap，第二行显示累计 `丢样 N`。
- **信号真断了**（衰落、停发）：等 20 秒（默认）才判中断；中断时半成品存成 `xxx-partial1.png`（不占正式编号），
  一旦同步脉冲在同一格点回来，就自动对齐、接着画，那个 partial 文件会被删掉。

只有源端真的换了一张图（新 VIS）才会另起一张。
`.app` 启动时没有终端，事件日志写到 `~/Library/Logs/SSTV Tool.log`，出问题先翻这个文件。

自测里有一条专门造这种洞：PD120 中间挖掉 15 秒 → 默认在 72 秒判 `signal lost`（278/496 行），
`--lost 30` 则撑到 348 行才收。

## 硬件接入

- 收：电台/对讲机喇叭对着麦克风能解，但不稳。正经做法是音频线进线路输入（USB 声卡），或者
  电阻衰减器把喇叭/线路输出降到麦克风电平——上游 README 里那段建议同样适用。
- 发：`--play` 直接把 WAV 放到默认输出；接电台时用音频线把输出接到电台的麦克风/数据口，
  电平用 `--gain` 调，别把电台的 ALC 打满。
- 采样率不用管：AUHAL 在输入方向**不做重采样**，程序会依次试设备原生率、48k、44.1k、32k，
  拿哪个能跑就用哪个，解码器本身 8k–48k 都吃。
- 时钟偏差由解码器自己拟合（报 ppm），收发两端晶振差几百 ppm 也能把图拉正。

## 自测都验了什么

`make test`（35 项，全绿）：

- 14 个模式各自编码→解码，核对存下来的 PNG 尺寸和完成状态、sync 命中数
- **14 个模式逐个走本工具自己的发射→接收闭环**（图 → WAV → 图），尺寸和 VIS 都对
- PD120 加 −400 ppm 时钟误差、−40 Hz 失谐、18 dB SNR：仍完整成图，报出 −400 ppm
- PD120 无 VIS：靠同步脉冲自动起图（autosync）
- 背靠背：Martin M1 + PD90 两张；四个模式连解；六张零间隙；六张各停 4 秒
- 一条命令多个文件：`--prefix` 连续编号不覆盖

人工看过的图：Robot 36 / PD120 / PD290 的彩条、灰阶、方框、圆圈都正，没有拉斜或串色错位；
发出去的图带 `--text` 时文字在解码结果里清楚可读；实时窗口在 `--simulate` 下逐行出图，
状态栏、电平表、调谐条、暂停/取消按钮都正常。

## 没做到的 / 已知边界

- 接收侧 PD120/160/180/240/290 存半尺寸（上游的 `SSTV_MAX_W 400` 内存约束，图画缓冲
  `IMG_BYTES` 按 Robot 36 尺寸算死，要全尺寸得改上游内存布局，不在这版范围）。发射侧是全尺寸编码。
- 没有 Wraase SC2 180（SSTVEncoder2 有）。上游的模式表里就没有这个模式。
- 没有图形界面的发射面板：发射走命令行（`encode`），没有"选图 → 选模式 → 点发射"的窗口。
- 实时链路的声学端到端：本机只有 webcam 麦克风，扬声器外放→麦克风收录时 VIS 位会翻
  （噪声大、房间混响），能锁上但解出来是噪声图；这不是解码器的问题，线路输入才作数。

## 许可

GPL-3.0（继承上游）。`src/sstv_dsp.c`、`src/sstv_dsp.h`、`tools/` 下的
`enc.c`、`sstv_tx.c`、`util.c` 来自 SodaGray/apricot-sstv，未修改；
`src/main.m`、`src/encode.m`、`src/audio_in.c`、`src/image_out.c` 是新增的 macOS 外壳。
