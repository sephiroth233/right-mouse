# 本机发行通道集成检查

这些客户端不打包进 RightMouse.app。只有显式设置 `RIGHTMOUSE_TEST_CLIENTS=1` 才会在构建目录外层生成签名测试客户端。构建临时私钥随后销毁，检查客户端与当前构建绑定，不能跨构建复用。

```bash
RIGHTMOUSE_TEST_CLIENTS=1 python3 scripts/build-local-app.py
open .build/local/RightMouse.app
python3 tools/RightMouseXPCCheck/run-checks.py
```

在应用中确认“本机连接已就绪”。如果选择了其他 `RIGHTMOUSE_BUILD_DIR`，构建和运行检查时使用同一个绝对路径。脚本通过真实 XPC 连接当前主应用，在 `.build/finder-xpc-acceptance/<UUID>` 下创建两个 TXT 文件并保存 `xpc-checks/results.json`。会受控重启本应用的连接转交服务一次。无管理员权限需求，不删除用户文件。

覆盖合法连接、同 ID 伪造签名、错误角色、缺失 mach-lookup 权限、握手前拒绝、真实文件创建、重复 requestID 去重、过期请求、无效负载和服务恢复。故意发送的无效负载可能使应用显示“操作未完成”，关闭该测试提示即可。旧 URL 的确认和会话单次执行等另外由 `scripts/check-host.sh` 检查。

脚本不能代替真实 Finder 菜单验收，也不能证明互联网下载后的 Gatekeeper 行为。正式交付证据见 [本机 XPC 验收记录](../../specs/001-finder-core/evidence/EV-local-xpc-delivery-001.md)。
