# 真实双卷文件引擎验收

## 目录

- [范围](#范围)
- [隔离方式](#隔离方式)
- [检查项](#检查项)
- [执行证据](#执行证据)
- [参考](#参考)

## 范围

本检查使用宿主临时目录与单独挂载的小型 APFS 磁盘镜像形成两个真实不同的 `st_dev`，验证文件引擎的真实跨卷路径。它不使用用户外置磁盘，不修改现有卷，也不构成拔盘、exFAT 或断电验收。

## 隔离方式

`scripts/check-volume.sh` 在随机临时目录创建 96 MiB 镜像，以 `-nobrowse -noautoopen` 挂载到同一临时目录中的专用 mount point。脚本只记录本次 attach 返回的设备；正常和异常退出时均只对该设备执行非 force detach。只有卸载成功且 mount table 查询成功并确认专用 mount point 已不再挂载时，才删除本次随机临时目录；卸载失败或无法确认挂载状态时，完整保留工作目录和镜像供人工处理。

## 检查项

- 宿主夹具与镜像挂载点的 `st_dev` 必须不同。
- 真实跨卷复制保留来源、提交目标并保持字节、POSIX mode 和扩展属性。
- 真实跨卷移动在目标提交并校验后才删除来源，不生成同卷 undo token。
- 流式复制阶段取消跨卷移动时，来源保留、最终目标不可见、私有 staging 被清理。
- 在隔离镜像内写入随机数据直到真实 `ENOSPC`，验证结构化 `NO_SPACE`、来源保留且最终目标不可见。

## 执行证据

2026-09-23 在 macOS 主机上实际执行：创建并挂载 96 MiB APFS 镜像，检查进程确认宿主夹具与挂载点的 `st_dev` 不同。最终输出：

```text
PASS volume total: 15
```

15 项均通过，包括真实跨卷复制、跨卷移动、POSIX mode、扩展属性、复制阶段取消和真实容量耗尽。脚本正常退出后使用 `hdiutil info` 检查，没有本次 `RightMouseCheck-*` 镜像保持挂载；随机 `rightmouse-volume.*` 工作目录也已删除。

本记录为 APFS 镜像上的真实双卷核心验收。真实拔盘、exFAT、Finder/TCC、断电和 UI 取消时序仍属于单独验收范围。

## 参考

- [独立双卷检查](../../../tools/RightMouseVolumeCheck/main.swift)
- [隔离镜像脚本](../../../scripts/check-volume.sh)
- [AC-009 与 AC-021 验收表](../checklists/acceptance.md)
