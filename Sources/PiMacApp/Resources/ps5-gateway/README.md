# 使用官方 FlClash 的实验性 PS5 IPv4 网关

## Pi Mac 内置界面

在「设置 → PS5 网关」中检查、授权开启和停止，无需终端。绿色状态仅在守护进程确认 TUN 与转发参数且心跳有效时出现；停止和正常退出会等待恢复结果。应用崩溃或租约过期也会触发恢复尝试，但强杀守护进程和系统崩溃仍无法保证恢复。

如果之前通过终端启动了旧脚本，请先在原终端按 Ctrl-C 并确认恢复，再从应用开启。已开启转发时不会接管其他会话。

以下是独立脚本的命令行用法；应用内不使用 Terminal，路径以实际脚本位置为准。

不修改 FlClash.app、订阅、数据库或覆写脚本。依赖官方客户端已有 TUN 路由。
目前机器检查结果：FlClash 0.8.99；全局模式；TUN mixed；auto-route、auto-detect-interface 开启；dns-hijack 为 any:53。Mac IPv4 为 192.168.0.150。

## 使用

先在路由器上为 Mac 保留 DHCP 地址，避免 192.168.0.150 改变。关闭针对 PS5 的 IPv6/RA，或使用没有 IPv6 的专用网络：仅设置 IPv4 网关不能阻止 IPv6 绕过。

只读检查（无需管理员权限）：

```sh
/usr/bin/python3 /Users/tianya/ps5-gateway/gateway.py
```

开启临时网关会话（由你在终端私下输入系统密码）：

```sh
sudo /usr/bin/python3 /Users/tianya/ps5-gateway/gateway.py --run
```

保持终端打开，Mac 不休眠，FlClash TUN 和全局模式保持开启，选择支持 UDP 转发的节点。

PS5 手动网络设置：

- IP：同网段的空闲地址，最好由路由器预留，不能与其他设备冲突。
- 子网掩码：使用路由器实际设置，不要盲目照填。
- 网关：192.168.0.150（以 Mac 当时实际 IPv4 为准）。
- 主 DNS：198.18.0.2。这不是 Mac 的 LAN 地址，而是进入 FlClash TUN 的地址；any:53 劫持负责解析。
- 次 DNS：若可留空则留空；若必须填，填同一地址，不要配置直连备用 DNS。
- 代理服务器：不使用。MTU：自动。

先测试网络，再启动游戏。在 FlClash 连接列表中确认出现 PS5 源 IP 的 TCP 和 UDP 连接，链路确实使用代理节点。需要实机验证下载、登录、游戏匹配和语音；仅连接测试成功不能证明 UDP 或无旁路。

## 恢复

按 Ctrl-C，脚本恢复它修改过的 sysctl 值。每秒检查一次 TUN 和核心 PID；TUN 消失或核心重启会终止会话。重新配置/切换节点后如果脚本退出，需要重新启动。

PS5 不再需要代理时，将 IP/网关/DNS 改回自动。

**强制杀死脚本、SIGKILL、机器崩溃无法执行恢复。** 本次检查原值为 forwarding=0、redirect=1。如果强制终止且没有其他网关服务依赖它们，可手动恢复：

```sh
sudo /usr/sbin/sysctl -w net.inet.ip.forwarding=0
sudo /usr/sbin/sysctl -w net.inet.ip.redirect=1
```

## 限制与安全

- 这是实验性 IPv4 旁路由辅助脚本，不是生产级软路由、VPN kill switch，也不保证“彻底代理”。未验证 PS5 实际 UDP/NAT 行为。
- 转发开关作用于整个 Mac，不只 PS5。仅在可信局域网使用；脚本不安装防火墙、源 IP 白名单或 NAT 规则。
- 检查通过说明存在匹配的 TUN 路由，不是密码学证明该接口归 FlClash 所有，也不能保证所有目的地址均经该接口。
- TUN 删除与下一次检测之间存在直连窗口；路由例外、客户端分流/UDP 直连回退、IPv6 都可能旁路。需要严格无泄漏时，应使用带防火墙出口约束的专用路由器方案。
- 开始时若 IPv4 转发已经开启则拒绝，避免干扰互联网共享/其他路由服务；不覆盖在会话期间被其他软件改动的参数。
- 节点必须支持 UDP；代理可能增加延迟并改变 NAT 类型。macOS 防火墙、Wi-Fi 客户端隔离和休眠会影响可用性。

测试不写系统参数：

```sh
cd /Users/tianya/ps5-gateway
/usr/bin/python3 -m unittest -v
```
