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

接收端在已认证握手里上报面板物理像素尺寸（`pixelsWide × pixelsHigh`）、脱敏后的 `host`／`model` 机器标识、精确硬件视频解码能力（`hevc444`、`hevc420`、`h264` 或旧版 `hevc`）及输入能力（`touch`、`tablet`）。发送端据此为任意主流分辨率与纵横比自动推导 5 档 HiDPI 比例缩放及物理尺寸提示，在 **系统设置 → 显示器** 中提供“更大文字 ↔ 更多空间”缩略档位（高密度屏默认 `1:1` HiDPI，标准密度默认 `1:1` 原生），并按 `(host, model, pixelsWide × pixelsHigh)` 记入 `~/Library/Application Support/LOCachy/display-modes.json` 供重连自动恢复。处于 `1:1` 档位时零缩放直出；其余档位经 Metal Mitchell 双三次（`B=1/3, C=1/3`）无黑边采样至面板物理像素，并自动按双方硬件能力优先级（`hevc444 → hevc → hevc420 → h264`）以 VideoToolbox 硬件编码输出。

LOCachy 的鼠标与触摸板可跨 Mac 的所有活动显示器自由移动；当接收端启用 `"touch"` 与 `"tablet"` 时，触摸屏多点手势（点按／拖拽／长按右键／双指滚动／捏合缩放）和主动手写笔数位屏事件（接近离开、笔／橡皮擦自动切换、压感、X/Y 倾斜角、悬停、笔身按键）均直接映射到扩展屏区域。拔出线缆后，虚拟显示器自动移除，服务继续等待下一次连接。
