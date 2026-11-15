# macOS 扩展屏发送端

面向 macOS 的 LOCachy 发送端。作为后台服务（`brew services start locachy-macos-sender`）或无参数启动时，静默监视可用的 Thunderbolt/USB4 IP 链路（无 Dock 图标、无需手动输入配对码），在 LOCachy 打开 `extdisplay` 时自动发现并自动连接。它在当前登录会话中新增一块虚拟显示器，用 ScreenCaptureKit 按接收端原生面板分辨率捕获该显示器，用 VideoToolbox 硬件编码为 HEVC Main 4:4:4（或回退 H.264），并通过链路发送给 LOCachy。LOCachy 的键盘和触摸板输入可跨 Mac 的所有显示器操作。

Thunderbolt/USB4 主机链路可以直连，也可以经过兼容的 Hub、Dock、显示器或菊花链。发送端使用实际生效的 Thunderbolt IP 接口（包括 macOS 的 Thunderbolt Bridge）。

## 上游来源与许可

虚拟显示器代码取自 `peetzweg/opendisplay` 提交 `0f44853adc5d44646a9e4d74e4516db460efb8bb`（发行版 1.30.2），归档 SHA-256 锁定在 `upstream.json` 中。`build.sh` 使用上游的四个文件（`VirtualDisplay.swift`、`OriginRestore.swift`、`VirtualCanvasSizing.swift`、`CGVirtualDisplayPrivate.h`），并应用 `patches/session-display.patch`。

上游以 GNU GPL 第 3 版发布（其 `LICENSE` 以哈希固定在 `upstream.json` 中）。本发送端文件为 GPL-3.0-or-later，合并构建产物按 GPL 第 3 版分发。

`CGVirtualDisplay` 是 CoreGraphics 私有接口；`--check` 报告相关类是否存在。

## 构建与检查

需要 Xcode 命令行工具、`curl` 和 `shasum`。测试还需要带 `ssl` 模块的 `python3`（OpenSSL 1.1.1 或更新版本）。

```sh
extdisplay-sender/macos/build.sh /tmp/locachy-macos-build          # CLI 与 app 包
extdisplay-sender/macos/tests/run-all.sh /tmp/locachy-macos-build  # 构建并运行全部检查
```

## 运行

通过 Homebrew 启动后台常驻服务：

```sh
brew services start locachy-macos-sender
```

后台服务监视已验证的 Thunderbolt IP 链路（包括 Hub 和菊花链使用的 macOS Thunderbolt Bridge），在 LOCachy 打开 `extdisplay` 时自动发现并建立连接。可在“系统设置 → 显示器”中切换并记忆 5 档“更大文字 ↔ 更多空间” HiDPI 缩放分辨率（`1080×720`、`1440×960`、`1728×1152`、`1920×1280`、`2160×1440`），视频流始终以面板完整物理像素输出。

诊断或脚本可使用手动 CLI：

```sh
locachy-macos-sender --interface <已验证的 Thunderbolt-IP 接口> --address <fe80::...%接口> --port 27183
```

需要 macOS 14 或更新版本。连接窗口显示屏幕录制、辅助功能的就绪状态及打开对应系统设置的按钮。

## 会话协议（已冻结）

**传输。** 接收端监听，发送端拨入。只接受已验证的 Thunderbolt IP 接口上的数字链路本地地址。自动发现使用限定接口的 Bonjour/DNS-SD `_locachy-ext._tcp.local.`（IPv6 链路本地地址与端口 27183）。TXT 记录携带 `pv=3`、`extended=1`、`pair=psk128` 及当次会话的 `code`。接收端在配对结束时撤销发布。

发送端通过 IOKit Thunderbolt IP 驱动祖先识别硬件，并通过 `/sbin/ifconfig 接口` 查询桥成员，仅接受成员全为 Thunderbolt IP 端口的网桥。

**TLS。**
- 仅 TLS 1.2，套件为 `TLS_PSK_WITH_AES_128_GCM_SHA256`（0x00A8）。
- PSK 身份为 `locachy-extdisplay-v1`；必须协商 ALPN `locachy-extdisplay-v1`。
- 禁用会话票据、会话恢复、证书与重新协商。
- 发送端在握手完成时校验协商版本、套件和 ALPN。

**会话密钥。** LOCachy 接入端为每个连接生成 16 个随机字节，编码为 RFC 4648 base32（26 个字符）。

## 协议

- `hello` 最先到达：`pv` 为 3，`locachy` 为 1，`extendedOnly` 为 true，包含面板物理像素尺寸、`videoCaps` 中的 H.264，以及五项输入能力。
- 发送端回复一次 `welcome`，随后发送 `streamConfig`（H.264、尺寸、最高 60 帧率）。
- 视频为带 4 字节起始码的 Annex-B 访问单元；每个 IDR 携带 SPS/PPS。
- `ping` 回复相同 `t` 的 `pong`；`closing` 结束会话。

输入：
- `key` 使用接收端的逻辑 keysym，按 Mac 当前键盘布局解析。Super 映射为 Command，Alt／AltGr 映射为 Option，Ctrl 映射为 Control。
- `button` 覆盖 272/273/274；`pointer` 为归一化位置。
- `scroll` 增量以流像素为单位（`phase` 0..4，`source` 0..4）。
- `cancel`（`scope` 为 `all`）释放全部按住的按键和按钮并结束滚动手势。

## 生命周期

一个会话拥有一块虚拟显示器。线缆断开或会话结束时，发送端释放按住的按键和按钮，停止捕获，移除虚拟显示器，并继续等待下一次连接。

参考监听端（`tests/tls-listener.py`）：

```sh
python3 -I tests/tls-listener.py 端口 <32 位十六进制> locachy-extdisplay-v1 locachy-extdisplay-v1 PSK-AES128-GCM-SHA256 1.2 日志文件
```
