#!/bin/sh

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    echo "错误: 必须使用 root 用户运行此脚本！"
    exit 1
fi

echo "正在增强 DNS 设置并锁定防止 DHCP 修改..."

# 1. 禁用 dhcpcd 对 resolv.conf 的接管 (核心步骤)
if [ -f /etc/dhcpcd.conf ]; then
    # 先删除已有的相关配置，防止重复写入
    sed -i '/nohook resolv.conf/d' /etc/dhcpcd.conf
    # 写入禁止钩子
    echo "nohook resolv.conf" >> /etc/dhcpcd.conf
    echo "已在 /etc/dhcpcd.conf 中禁用 resolv.conf 钩子。"
fi

# 2. 禁用 udhcpc 的修改权限
mkdir -p /etc/udhcpc/
echo "RESOLV_CONF=no" > /etc/udhcpc/udhcpc.conf

# 3. 创建本地启动脚本 (确保每次开机最后一步再次强刷)
# 确保 local 服务已启用
rc-update add local default >/dev/null 2>&1

cat << 'EOF' > /etc/local.d/dns.start
#!/bin/sh
# 强行重写 resolv.conf 为纯 IPv6 优化 DNS
cat << 'DNS' > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 2001:4860:4860::8888
nameserver 2001:4860:4860::8844
DNS
EOF

# 4. 设置脚本权限
chmod +x /etc/local.d/dns.start

# 5. 立即执行一次以生效
/etc/local.d/dns.start

echo "------------------------------------------"
echo "设置完成！"
echo "已配置以下 DNS (优先 NAT64 解析):"
cat /etc/resolv.conf
echo "------------------------------------------"
echo "提示: 重启后可使用 'nslookup google.com' 验证。"
