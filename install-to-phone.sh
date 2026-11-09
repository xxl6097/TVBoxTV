#!/bin/bash

# 夜帧影视 HarmonyOS 真机安装脚本
# 用法: ./install-to-phone.sh

set -e

APP_NAME="夜帧影视"
PKG_NAME="com.abber.nightframe"
HAP_FILE="build/debug/${APP_NAME}-debug.hap"
ACTIVITY="com.abber.nightframe/.MainActivity"

echo "📱 ${APP_NAME} - 真机安装工具"
echo "=================================="
echo ""

# 检查 HAP 文件
if [ ! -f "$HAP_FILE" ]; then
    echo "❌ 错误: 找不到 $HAP_FILE"
    echo "   请先运行: bash scripts/build.sh"
    exit 1
fi

echo "✅ 产物检查: $(ls -lh $HAP_FILE | awk '{print $5}')"
echo ""

# 检查设备
echo "🔍 扫描设备..."
hdc list targets

echo ""
echo "📦 开始安装..."
echo ""

# 安装
if hdc install "$HAP_FILE"; then
    echo ""
    echo "✅ 安装成功!"
    echo ""
    echo "🚀 启动应用？ (y/n)"
    read -r choice
    if [ "$choice" = "y" ]; then
        echo "启动中..."
        hdc shell aa start "$ACTIVITY" || echo "⚠️ 可能需要在手机上手动启动"
        echo "✅ 应用已启动"
    fi
else
    echo ""
    echo "❌ 安装失败"
    echo ""
    echo "可能的原因："
    echo "1. USB 线未连接"
    echo "2. 手机未启用开发者模式"
    echo "3. 网络不在同一网段（见 INSTALL_GUIDE.md）"
    exit 1
fi

echo ""
echo "📝 后续操作:"
echo "  - 查看应用日志:   hdc shell cat /data/log/${PKG_NAME}.log"
echo "  - 卸载应用:       hdc uninstall ${PKG_NAME}"
echo "  - 清空应用数据:   hdc shell pm clear ${PKG_NAME}"
echo ""
echo "✅ 完成!"
