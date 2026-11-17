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

接收端在已认证握手里上报面板物理像素尺寸（`pixelsWide × pixelsHigh`）及脱敏后的 `host`／`model` 机器标识。发送端按物理尺寸计算 `1:1` 基础几何（高密度且可整除为偶数逻辑点时采用 `@2x` HiDPI，否则 `@1x`），在 **系统设置 → 显示器** 中提供五档比例缩放模式（`2.0×`、`1.75×`、`1.5×`、`1.25×`、`1.0×`，对应“更大文字 ↔ 更多空间”），并按 `(host, model, pixelsWide × pixelsHigh)` 查询本机模式表（`~/Library/Application Support/LOCachy/display-modes.json`）：首次连接默认使用 `1:1`，之后会记住每台机器选定的缩放档位并在重连／重插时直接恢复。处于 1:1 模式时零缩放直出；切到中间分数 HiDPI 档位时按原生 HiDPI 分辨率采样并经 Metal Mitchell 双三次（`B=1/3, C=1/3`）无黑边下采样至面板物理像素，再由硬件 HEVC 4:4:4（或回退 H.264）编码输出。

LOCachy 的键盘、触摸板与鼠标输入可跨 Mac 的所有活动显示器使用。拔出线缆后，虚拟显示器自动移除，服务继续在后台等待下一次连接。
