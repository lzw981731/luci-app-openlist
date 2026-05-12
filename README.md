# luci-app-openlist

🗂️ 一个支持多种存储的文件列表程序，基于 Gin 和 Solidjs 构建。

本仓库提供：

- **openlist** — OpenList 核心程序（Go 语言，从源码编译）
- **luci-app-openlistui** — 功能完善的 LuCI Web 管理界面（基于 [drfccv/luci-app-openlistui](https://github.com/drfccv/luci-app-openlistui)）

## 功能特性

### 系统概览

- 实时系统状态仪表盘（CPU、内存、磁盘使用情况）
- OpenList 服务运行状态与进程监控
- 快速启动 / 停止 / 重启服务
- 组件版本信息展示

### 更新管理

- 从 GitHub Releases 检查 OpenList 核心和前端更新
- 一键下载更新，自动检测系统架构
- 支持 GitHub 代理，方便国内用户使用
- 支持 GitHub Token 认证，避免 API 速率限制

### 日志查看

- 实时日志监控，支持自动刷新
- 日志过滤与搜索
- 可配置日志保留时间和轮转策略

### 设置管理

- 基于 UCI 的配置管理（`/etc/config/openlistui`）
- HTTP/HTTPS 端口配置
- 数据目录和缓存目录设置
- 开机自启开关
- 防火墙规则管理（WAN 外部访问）
- 响应式设计，支持手机和桌面端访问

## 如何编译

- 安装 `libfuse` 开发包：

  - ubuntu/debian：
    ```shell
    sudo apt update
    sudo apt install libfuse-dev
    ```

  - redhat：
    ```shell
    sudo yum install fuse-devel
    ```

  - arch：
    ```shell
    sudo pacman -S fuse2
    ```

- 进入你的 OpenWrt 源码目录

- OpenWrt 官方 SnapShots

  *1. 需要 golang 1.24.x 或更高版本（修复旧版 OpenWrt 分支的编译问题）*
  ```shell
  rm -rf feeds/packages/lang/golang
  git clone https://github.com/sbwml/packages_lang_golang -b 24.x feeds/packages/lang/golang
  ```

  *2. 获取 luci-app-openlist 源码并编译*
  ```shell
  git clone https://github.com/lzw981731/luci-app-openlist package/openlist
  make menuconfig # 选择 LUCI -> Applications -> luci-app-openlistui
  make package/openlist/luci-app-openlistui/compile V=s # 编译 luci-app-openlistui
  ```

--------------

## 如何安装预编译包（LuCI2）

- 登录 OpenWrt 终端（SSH）

- 安装 `curl` 包
  ```shell
  # opkg 包管理器（openwrt 21.02 ~ 24.10）
  opkg update
  opkg install curl

  # apk 包管理器
  apk update
  apk add curl
  ```

- 执行安装脚本（支持多架构）
  ```shell
  sh -c "$(curl -ksS https://raw.githubusercontent.com/lzw981731/luci-app-openlist/main/install_openlist.sh)"
  ```

--------------

![luci-app-openlist](https://github.com/user-attachments/assets/50d8ee3a-e589-4285-922a-40c82f96b9f5)
