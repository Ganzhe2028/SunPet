<p align="center">
  <img src="Assets/face.png" width="180" alt="孙宇晨桌宠头像">
</p>

<h1 align="center">你说太对了 · SunPet</h1>

<p align="center">一个住在 macOS 桌面上的「太对了」。点一下，他就说一句。</p>

<p align="center">
  <img alt="macOS 14+ / Apple Silicon" src="https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-black">
  <img alt="no dependencies" src="https://img.shields.io/badge/dependencies-none-brightgreen">
  <img alt="license MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

---

## 这是什么

28 段原声「太对了」，做成一个桌面小挂件。

点头像，他说话。拖着他，换个地方待着。摇一下笔记本，他也接一句。右键能挑句子、调音量、改大小。不点头像的时候，他就安静地待在屏幕角落，不占 Dock，不打扰你。

不开摄像头，不开麦克风，不要管理员权限，不联网。退出就是真的退了。

> 素材来自一段四个小时的采访（[BV1fcHD6cEw3](https://www.bilibili.com/video/BV1fcHD6cEw3/)）。那位嘉宾在这四个小时里说了二十八次「太对了」。有人把它们一个个捡了出来，于是就有了这个东西。

## 装起来

### 一句话版（如果你有 AI agent）

把下面这段整段复制给你的 agent：

> 帮我安装 SunPet 桌宠。执行：`git clone https://github.com/Ganzhe2028/你说太对了-SunPet.git ~/Applications/SunPet && cd ~/Applications/SunPet && ./build.sh && open build/SunPet.app`。前提是 macOS 14+ Apple Silicon，只需要 Xcode Command Line Tools 里的 swiftc，不需要 sudo，也不要改任何系统安全设置。装完确认进程在跑、悬浮窗可见，然后把 `build/SunPet.app` 挪进 /Applications。

更细的约束写在下面的[给 Agent 的说明](#给-agent-的说明)里。

### 自己动手（三步）

需要 macOS 14 或更新、Apple Silicon 的 Mac，以及命令行工具。没装过命令行工具的话，先在终端跑一次 `xcode-select --install`。

```bash
git clone https://github.com/Ganzhe2028/你说太对了-SunPet.git
cd 你说太对了-SunPet
./build.sh
open build/SunPet.app
```

编译十几秒，不下载任何依赖。想长期留着，就把 `build/SunPet.app` 拖进「应用程序」。

第一次打开如果被系统拦（本地签名，没做 Apple 公证），右键点它 → 打开，之后就正常了。

## 怎么玩

| 动作 | 会发生什么 |
| --- | --- |
| 点一下头像 | 随机说一句。28 句播完一轮之前不重复，连点也不会叠着播 |
| 拖着头像 | 换个位置，退出后还记得 |
| 摇一下电脑 | 说一句（正在说话时不打断） |
| 右键头像 | 全部设置 |
| 点菜单栏的「太对了」 | 同一个菜单 |

菜单里能改的东西：挑句子、停止播放、音量、头像大小、移回屏幕右下角、开关机身摇晃、退出。

### 固定某一句

右键 → **播放方式** → **固定播一句**。

之后不管点头像还是摇机身，都只播这一句。

想换是哪一句：右键 → **挑一句** → 点那一条。它会打勾，并且立刻变成新的固定句。切回 **随机一句** 就恢复轮播。

这个选择会记在系统里，退出重开还是你那句。存的选择要是坏掉了（比如对应文件没了），会自动退回随机，不会卡在静音上。

### 摇一摇是怎么做到的

读 Mac 自带的加速度计（Apple SPU）。不碰麦克风和摄像头。

这个接口 Apple 没有公开承诺过，不同机型、不同系统版本可能读不到。连上了菜单里会显示「机身摇晃：已连接」，读不到会显示原因、功能自动关掉，不会影响其他部分。

传感器读取跑在独立子进程里，只走本机回环地址，跟你退出时一起结束。

## 系统要求

- **Apple Silicon（arm64）**。Intel Mac 跑不了，构建脚本里写死了 arm64
- **macOS 14 及以上**
- 大约 4 MB 磁盘

## 给 Agent 的说明

如果你是被指派来安装这个东西的 AI agent，需要知道这些：

- 产物是 `build/SunPet.app`：ad-hoc 本地签名，没有公证，`LSUIElement` 为 true，没有 Dock 图标，只有一个置顶悬浮窗
- 唯一依赖是 `swiftc`（Xcode Command Line Tools 自带）。没有 npm，没有 pip，构建过程不联网
- 不需要 sudo，不需要辅助功能、屏幕录制、麦克风、摄像头权限。不要为了「让它能用」去改系统安全设置
- 验证装好了：`pgrep -fl "SunPet.app/Contents/MacOS/SunPet"` 应该看到一个主进程加一个 `--motion-helper` 子进程。更严谨一点，查窗口是否存在（`onscreen=1 alpha=1`）
- 自检：`./build/SunPet.app/Contents/MacOS/SunPet --self-test` —— 会跑完 28 条音频、摇晃检测器、菜单结构、固定模式不变量，最后打印 `PASS`
- 读当前设置：`--dump-mode`，输出 `mode=random|fixed pinned=<id> valid=<bool>`
- 设置存在 `defaults` 域 `com.ganzhe2028.sunpet`
- 卸载：退出进程，删掉 app，再 `defaults delete com.ganzhe2028.sunpet`

## 自己改

| 文件 | 干什么的 |
| --- | --- |
| `Sources/main.swift` | 窗口、菜单、播放、播放方式、自检 |
| `Sources/Motion.swift` | 加速度计读取、摇晃判定、进程间通信 |
| `Assets/clips.json` | 句子清单：编号、文案、时间码、文件名、时长 |
| `Assets/Clips/*.m4a` | 28 段音频 |
| `Assets/face.png` | 头像 |
| `build.sh` | 编译、打包、签名，26 行 |

想换声音：把你的 m4a 放进 `Assets/Clips/`，改 `Assets/clips.json` 里的 `file` 和 `label`，重新 `./build.sh`。想换脸：替换 `Assets/face.png` 就行。

## 素材来源与声明

- **音频**：B 站 [对话孙宇晨：年轻人如何抓住 AI 时代的机会？](https://www.bilibili.com/video/BV1fcHD6cEw3/) 里的 28 个时间点，逐句截取，用原声，没有做变声或语音克隆。具体时间码在 `Assets/clips.json`，可以逐条核对
- **头像**：公开照片，做了去背景处理
- 音频和头像的版权属于原权利人，**不在 MIT 许可范围内**。这个仓库只做学习交流和玩梗，不商用。权利人如果觉得不合适，开个 issue，会移除
- 代码用 MIT

## License

代码 MIT，见 [LICENSE](LICENSE)。音频、头像等素材版权归原权利人所有。
