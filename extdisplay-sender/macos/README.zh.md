# macOS 扩展屏发送端

配合 LOCachy `extdisplay` 接收器使用的 macOS 后台发送端。

## 安装与后台服务

从 `niuyuanzhao/locachy` Homebrew tap 安装。如需内核级虚拟 USB 键盘原装直通（完整支持长按 Command/Meta、跨设备修饰键组合、系统热键与安全密码框），推荐安装 `locachy-virtual-hid` Cask（会自动列管固定版本的 `karabiner-driverkit-virtualhiddevice` DriverKit 扩展、`locachy-macos-sender` Formula 以及 root 辅助守护进程 `locachy-hid-helper`）：

```sh
brew tap niuyuanzhao/locachy
brew install --cask locachy-virtual-hid
brew services start locachy-macos-sender
```

若仅需无驱动的用户态发送端（使用物理键码 1:1 直通的 `CGEventPost`）：

```sh
brew install niuyuanzhao/locachy/locachy-macos-sender
brew services start locachy-macos-sender
```

首次使用时：
- 在 **系统设置 → 隐私与安全性** 中为 `LOCachy Extended Display` 授予 **屏幕录制** 与 **辅助功能** 权限。
- 若安装了 `locachy-virtual-hid`，请在 **系统设置 → 登录项与扩展 → 驱动程序扩展**（或 **隐私与安全性**）中批准 **Karabiner-DriverKit-VirtualHIDDevice** 扩展。在批准生效前，键盘会自动无缝回退到物理键码 1:1 的 `CGEventPost` 模式。

通过雷电／USB4 线缆、Hub、Dock 或菊花链连接并在 LOCachy 上打开 `extdisplay` 后，后台服务会自动发现接收器并建立连接。

## 显示几何与输入转发

接收端在已认证握手里上报面板物理像素尺寸（`pixelsWide × pixelsHigh`）、脱敏后的 `host`／`model` 机器标识、精确硬件视频解码能力（`hevc444`、`hevc420`、`h264` 或旧版 `hevc`）及输入能力（`touch`、`tablet`）。发送端据此为任意主流分辨率与纵横比自动推导 5 档 HiDPI 比例缩放及物理尺寸提示，在 **系统设置 → 显示器** 中提供“更大文字 ↔ 更多空间”缩略档位（高密度屏默认 `1:1` HiDPI，标准密度默认 `1:1` 原生），并按 `(host, model, pixelsWide × pixelsHigh)` 记入 `~/Library/Application Support/LOCachy/display-modes.json` 供重连自动恢复。处于 `1:1` 档位时零缩放直出；其余档位经 Metal Mitchell 双三次（`B=1/3, C=1/3`）无黑边采样至面板物理像素，并自动按双方硬件能力优先级（`hevc444 → hevc → hevc420 → h264`）以 VideoToolbox 硬件编码输出。

键盘转发保留物理 1:1 evdev 扫描码，让 macOS 原生接管键盘布局、输入法与修饰键状态：
- 当 `locachy-hid-helper` 守护进程与 `Karabiner-DriverKit-VirtualHIDDevice` 驱动扩展就绪时，evdev 键码直接编码为标准 USB HID Keyboard／Consumer 报告注入虚拟 USB 键盘。`locachy-hid-helper` 通过内核 `audit_token`、当前控制台用户 UID、可执行文件路径和签名标识（`org.locachy.extdisplay.sender`）严格校验连接者身份，并在发送端断开或退出时立即发送全键释放与重置报告，避免任何修饰键卡死。
- 当驱动扩展未安装、尚未批准或协议版本不匹配时，自动回退到物理 evdev → macOS 硬件 `CGKeyCode` 的 1:1 `CGEventPost` 注入（仅对无物理扫描码映射的特殊符号回退逻辑 `keysym` 查表）。

LOCachy 的鼠标与触摸板可跨 Mac 的所有活动显示器自由移动；当接收端启用 `"touch"` 与 `"tablet"` 时，触摸屏多点手势（点按／拖拽／长按右键／双指滚动／捏合缩放）和主动手写笔数位屏事件（接近离开、笔／橡皮擦自动切换、压感、X/Y 倾斜角、悬停、笔身按键）均直接映射到扩展屏区域。拔出线缆后，虚拟显示器自动移除，服务继续等待下一次连接。
