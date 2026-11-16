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

## 显示几何与输入转发

接收端在握手时上报其面板的物理像素尺寸（`pixelsWide × pixelsHigh`）。发送端仅在握手后按该物理尺寸计算一对一的虚拟显示器几何（高密度且可整除为偶数逻辑点时采用 `@2x` HiDPI，否则为 `@1x`，不保留本地模式预设，也不提供分数降采样缩放模式），并始终以面板物理像素分辨率通过硬件 HEVC 4:4:4（或回退 H.264）传输画面。

LOCachy 的键盘、触摸板与鼠标输入可跨 Mac 的所有活动显示器使用。拔出线缆后，虚拟显示器自动移除，服务继续在后台等待下一次连接。
