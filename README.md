# OpenWrt Overlay 全自动扩容脚本

针对 OpenWrt/ImmortalWrt 官方 x86_64 镜像（squashfs + f2fs overlay 布局）的全自动一键扩容脚本。

## 问题

官方镜像（squashfs combined）默认给 overlay 只分配 300MB，磁盘/虚拟磁盘剩余空间无法直接使用。
eMMC/SATA/NVMe/虚拟机磁盘调大后，overlay 空间依然是 300MB。

## 特性

- **全自动**：执行后 2 次自动重启，全程无需人工介入（不进 failsafe）
- **通用**：自动检测 root 分区、loop 偏移、PARTUUID、起始扇区
- **安全**：fdisk 专家模式保留原 PARTUUID，grub 引导无需修改；自动备份 grub.cfg
- **适配 f2fs**：官方 expand_root 只支持 ext4（resize2fs），本脚本使用 losetup + fsck + resize.f2fs

## 使用方法

```sh
# 方式1: 上传后执行
scp expand-overlay.sh root@<ip>:/tmp/
ssh root@<ip> "sh /tmp/expand-overlay.sh"

# 方式2: 从服务器拉取执行（适合批量装机）
wget -qO- http://<server>/expand-overlay.sh | sh
```

## 原理

1. **阶段0**：fdisk 删除 root 分区重建并扩展到全盘（保留起始扇区，专家模式把分区 UUID 改回原值，grub 的 PARTUUID 不用改）
2. 写入 `/etc/uci-defaults/80-rootfs-resize` 自启脚本，重启
3. **阶段1**：uci-defaults 自动执行——losetup 用原偏移挂载新 loop → fsck → mount/umount 重放日志 → `resize.f2fs -f` 扩展到全盘 → 标记完成 → 自动重启
4. **阶段2**：扩容完成，overlay 即为全盘大小

## 日志

- 阶段0: `/tmp/expand-overlay.log`
- 阶段1: `/tmp/expand-stage1.log`

## 备份/恢复

- grub 备份: `/boot/grub/grub.cfg.bak-expand`
- 阶段1 重复执行防护: `/etc/rootfs-resize-done`
