# Apricot SSTV for macOS (arm64)

把 [SodaGray/apricot-sstv](https://github.com/SodaGray/apricot-sstv)（iPod nano 7 上的 SSTV 接收机）
的解码核心原样搬到 macOS，配上桌面端该有的输入输出：文件解码、实时采集、滚动预览窗口、PNG 落盘。

解码核心 `src/sstv_dsp.c` 是上游那份（GPL-3.0，未改动）：解调、VIS 检测、无 VIS 自动锁同步、
斜率校正（报 ppm）、衰落/丢包续画，一行没动；换掉的是采集层（CoreAudio AUHAL 代替 nano 的 DMA）、
显示层（AppKit 代替 320×240 RAW surface）和保存层（ImageIO PNG 代替 BMP）。

## 自动识别，不用选模式

窗口里没有模式下拉框，因为不需要：收到信号先读 VIS 头定模式（14 种全覆盖），
VIS 丢了（信号开头没抄到、被压掉）就退一步用行同步脉冲的周期和 sync 长度去匹配锁定。
一晚上换四五个模式、中途改模式都行，解完一张自动回到"听"，下一张按新 VIS 重新认。

一张解完自动存图、立刻回到聆听，不用点任何东西——下一张照常按它自己的 VIS 认模式。
自测里有三条专门的：

- Robot 36 → Robot 72 → Martin M1 → Martin M2 四段首尾相接（288 秒一个文件），连解四张
- 六张连着来、中间一点空隙都没有：六张全出
- 六张之间各停 4 秒（真人换模式）：同样六张全出

`apricot-sstv --modes` 打印这个构建实际能解的模式（问解码器自己，不是写死的表）。
顺带一句：VIS 4（Robot 24）解码器认得名字但不解——上游也没实现，会显示 `Skip Robot 24`。

## 支持的 14 个模式

| 模式 | VIS | 画幅 | 时长 | 存储尺寸（解码后 PNG） |
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

宽于 400 px 的模式按半尺寸存（上游的固定内存策略），每个像素取两倍宽度采样、每 sync 的两行平均。
`--scale 2` 可以让 PNG 存成两倍尺寸（最近邻放大，看着更舒服，但不会多出细节）。

## 编译

需要 Xcode Command Line Tools（clang）。arm64 原生，无第三方库。

```sh
make            # build/apricot-sstv + build/Apricot SSTV.app + 测试信号工具
make test       # 14 个模式 + 干扰信号 + 背靠背两图 + 多文件，全自动自测
sudo make install   # 装到 /usr/local/bin/apricot-sstv（可选）
```

## 用法

```sh
# 解一段录音（wav/aiff/m4a/flac/caf 都行，CoreAudio 能读的都能读）
apricot-sstv ~/Desktop/sdr-2026-11-06.wav
# → 同目录下 sdr-2026-11-06-1.png、-2.png ...；录到一半的信号也会存一张

# 实时接收（电台/对讲机音频进线路输入或麦克风口）
apricot-sstv --listen
apricot-sstv --list                  # 先看设备编号
apricot-sstv --listen --device 1     # 指定设备
apricot-sstv --listen --no-view      # 不要窗口，日志 + 自动存图

# 把一个文件按真实速度走一遍实时链路（调窗口布局、验证录到的信号用）
apricot-sstv --simulate recording.wav
```

常用参数：`--out DIR` 输出目录、`--prefix NAME` 文件名前缀、`--scale N` 放大存图、
`--no-autosync` 不听同步脉冲自动起图、`--ppm N` 给时钟误差先验、`--quiet` 静音模式。

窗口里：上方三行是状态（模式/行数、调谐 Hz 与偏移、时钟 ppm、同步 x/y、电平 dBFS、已存文件），
底下两条是电平表和调谐条（红区是 1500–2300 Hz 的 sync/porch 频段）。`q` 或 Esc 退出。

`build/Apricot SSTV.app` 双击即进实时模式：它是独立 TCC 身份，麦克风授权会记在"Apricot SSTV"名下，
之后重建也不会再问。命令行版跑在自己的终端名下，需要终端在
系统设置 → 隐私与安全性 → 麦克风 里被勾选。

## 装进"应用程序"和 Dock（可选）

```sh
make app && cp -R "build/Apricot SSTV.app" /Applications/   # 装进应用程序（Launchpad 里就有）
open -a "/Applications/Apricot SSTV.app"                    # 启动
```

Dock：启动后在 Dock 图标上右键 → 选项 → 在 Dock 中保留；或者直接
`defaults write com.apple.dock persistent-apps -array-add '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file:///Applications/Apricot%20SSTV.app/</string><key>_CFURLStringType</key><integer>15</integer></dict><key>file-label</key><string>Apricot SSTV</string><key>file-type</key><integer>41</integer></dict><key>tile-type</key><string>file-tile</string></dict>' && killall Dock`
（首次启动会弹麦克风授权，点"允许"即可；权限记在 com.lan.apricot-sstv 名下。）

图标是 `assets/AppIcon-1024.png`（就是一张解出来的测试卡，圆角由 `tools/makeicon.c` 现切），
想换：`make icon SRC=别的图.png`。`assets/AppIcon.icns` 由 Makefile 用 sips + iconutil 生成。

## 硬件接入

- 电台/对讲机喇叭对着麦克风能解，但不稳。正经做法是音频线进线路输入（USB 声卡），或者
  电阻衰减器把喇叭/线路输出降到麦克风电平——上游 README 里那段建议同样适用。
- 采样率不用管：AUHAL 在输入方向**不做重采样**，程序会依次试设备原生率、48k、44.1k、32k，
  拿哪个能跑就用哪个，解码器本身 8k–48k 都吃。
- 时钟偏差由解码器自己拟合（报 ppm），收发两端晶振差几百 ppm 也能把图拉正。

## 自测都验了什么

`make test`（21 项，全绿）：

- 14 个模式各自编码→解码，核对存下来的 PNG 尺寸和完成状态、sync 命中数
- PD120 加 −400 ppm 时钟误差、−40 Hz 失谐、18 dB SNR：仍完整成图，报出 −400 ppm
- PD120 无 VIS：靠同步脉冲自动起图（autosync）
- Martin M1 + PD90 拼成一段：出两张图
- 一条命令多个文件：`--prefix` 连续编号不覆盖
- 四个模式首尾相接（Robot 36 / Robot 72 / Martin M1 / Martin M2）：自动切换，四张全出

另外人工看过图：Robot 36 / PD120 的彩条、灰阶、方框、圆圈都正，没有拉斜或串色错位；
实时窗口在 `--simulate` 下逐行出图，状态栏、电平表、调谐条都正常。

## 没做到的 / 已知边界

- PD120/160/180/240/290 存半尺寸（上游的 `SSTV_MAX_W 400` 内存约束，图画缓冲
  `IMG_BYTES` 按 Robot 36 尺寸算死，要全尺寸得改上游内存布局，不在这版范围）。
- 没有 macOS 端的 SSTV **发射**：上游 host 目录里的 `sstv_tx` 只拿来造测试信号。
- 实时链路的声学端到端：本机只有 webcam 麦克风，扬声器外放→麦克风收录时 VIS 位会翻
  （噪声大、房间混响），能锁上但解出来是噪声图；这不是解码器的问题，线路输入才作数。

## 许可

GPL-3.0（继承上游）。`src/sstv_dsp.c`、`src/sstv_dsp.h`、`tools/` 下的
`enc.c`、`sstv_tx.c`、`util.c` 来自 SodaGray/apricot-sstv，未修改；
`src/main.m`、`src/audio_in.c`、`src/image_out.c` 是新增的 macOS 外壳。
