#!/bin/sh

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# 1. 环境检测
echo -e "${BLUE}>>> 正在检测系统环境...${NC}"
if [ -x "$(command -v apk)" ]; then
    PM="apk"
    KEYWORD="SNAPSHOT"
    EXT="apk"
    echo -e "${GREEN}检测到新版系统 (APK 环境)${NC}"
elif [ -x "$(command -v opkg)" ]; then
    PM="opkg"
    KEYWORD="openwrt-"
    EXT="ipk"
    echo -e "${GREEN}检测到传统系统 (OPKG 环境)${NC}"
else
    echo -e "${RED}错误: 未检测到 apk 或 opkg，脚本停止。${NC}"
    exit 1
fi

# 2. 架构检测
ARCH=$(ubus call system board | grep '"architecture":' | cut -d '"' -f 4)
[ -z "$ARCH" ] && ARCH=$(uname -m)
echo -e "${GREEN}系统架构: ${ARCH}${NC}"

# 3. 选择下载源
echo "--------------------------------"
echo "1) 原始 GitHub 地址"
echo "2) 国内加速下载"
echo "--------------------------------"
read -p "请输入数字 [1-2]: " DOWNLOAD_CHOICE

PROXY=""
[ "$DOWNLOAD_CHOICE" = "2" ] && PROXY="https://gh-proxy.com/"

# 4. 获取版本信息
echo -e "${BLUE}>>> 正在检索最新版本并匹配 ${KEYWORD}...${NC}"
API_URL="https://api.github.com/repos/lzw981731/luci-app-openlist/releases/latest"
RELEASE_DATA=$(curl -sL ${PROXY}${API_URL})

# 智能过滤：匹配 架构 + 对应后缀 + 对应包管理器标识
DOWNLOAD_URL=$(echo "$RELEASE_DATA" | grep "browser_download_url" | grep "$ARCH" | grep "$KEYWORD" | grep "tar.gz" | head -n 1 | cut -d '"' -f 4)

if [ -z "$DOWNLOAD_URL" ]; then
    echo -e "${RED}错误: 无法在 Release 中找到匹配 ${ARCH} 和 ${KEYWORD} 的 tar.gz 文件。${NC}"
    exit 1
fi

FILE_NAME=$(basename "$DOWNLOAD_URL")
echo -e "${GREEN}匹配到目标文件: ${FILE_NAME}${NC}"

# 5. 下载与准备
echo -e "${BLUE}>>> 正在下载到 /tmp...${NC}"
curl -L "${PROXY}${DOWNLOAD_URL}" -o "/tmp/$FILE_NAME"

# 6. 解压并进入目录
echo -e "${BLUE}>>> 正在解压...${NC}"
mkdir -p /tmp/openlist_temp
tar -zxf "/tmp/$FILE_NAME" -C /tmp/openlist_temp
# 进入真正的安装包目录
cd /tmp/openlist_temp/packages_ci 2>/dev/null || { echo -e "${RED}错误: 未找到 packages_ci 文件夹。${NC}"; exit 1; }

# 7. 安装逻辑
install_package() {
    local force=$1
    if [ "$PM" = "apk" ]; then
        if [ "$force" = "yes" ]; then
            echo -e "${BLUE}尝试强制安装 (APK --allow-untrusted --force-broken-world)...${NC}"
            apk add --allow-untrusted --force-broken-world *.$EXT
        else
            apk add --allow-untrusted *.$EXT
        fi
    else
        if [ "$force" = "yes" ]; then
            echo -e "${BLUE}尝试强制安装 (OPKG --force-depends)...${NC}"
            opkg install --force-depends *.$EXT
        else
            opkg install *.$EXT
        fi
    fi
}

echo -e "${BLUE}>>> 尝试普通安装...${NC}"
install_package "no"

# 检查安装状态
if [ $? -ne 0 ]; then
    echo -e "\n${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    echo -e "${RED}常规安装失败！可能是由于依赖冲突或固件版本不匹配。${NC}"
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    read -p "是否尝试强制安装？(可能会忽略依赖风险) [y/N]: " CONFIRM
    case "$CONFIRM" in
        [yY][eE][sS]|[yY])
            install_package "yes"
            ;;
        *)
            echo -e "${BLUE}已取消强制安装。${NC}"
            ;;
    esac
fi

# 8. 刷新缓存与清理
echo -e "${BLUE}>>> 刷新 LuCI 缓存...${NC}"
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
/etc/init.d/rpcd restart 2>/dev/null

echo -e "${GREEN}---------------------------------------${NC}"
echo -e "${GREEN}操作执行完毕！请检查后台菜单。${NC}"
echo -e "${GREEN}---------------------------------------${NC}"

# 清理垃圾
rm -rf /tmp/openlist_temp "/tmp/$FILE_NAME" /tmp/install_openlist.sh
