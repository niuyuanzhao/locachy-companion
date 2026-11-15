# macOS 扩展屏发送端

配合 LOCachy `extdisplay` 接收器使用的 macOS 后台发送端。

## 安装与后台服务

通过 `niuyuanzhao/locachy` Homebrew tap 安装并启动常驻服务：

```sh
brew tap niuyuanzhao/locachy
brew install locachy-macos-sender
brew services start locachy-macos-sender
```

首次使用时，在 **系统设置 → 隐私与安全性** 中为 `LOCachy Extended Display` 授予 **屏幕录制** 与 **辅助功能** 权限。

通过雷电／USB4 线缆、Hub、Dock 或菊花链连接并在 LOCachy 上打开 `extdisplay` 后，后台服务会自动发现接收器并建立连接。

## 显示模式与输入转发

接收端在握手时上报其面板的物理像素尺寸（`pixelsWide × pixelsHigh`）。发送端据此创建虚拟显示器，并按面板尺寸比例自动派生 5 档缩放模式（`2.0×`、`1.75×`、`1.5×`、`1.25×`、`1.0×`）供 **系统设置 → 显示器** 选择与记忆；视频流始终按面板物理像素分辨率以硬件 HEVC 4:4:4（或回退 H.264）输出。

LOCachy 的键盘、触摸板与鼠标输入可跨 Mac 的所有活动显示器使用。拔出线缆后，虚拟显示器自动移除，服务继续在后台等待下一次连接。
