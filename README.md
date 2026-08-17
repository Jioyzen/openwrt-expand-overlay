# OpenWrt Overlay 全自动扩容（控制机一键版）

针对 OpenWrt/ImmortalWrt 官方 x86_64 镜像（squashfs + f2fs overlay）的**控制机一键扩容工具**。
解决新装机/虚拟磁盘调大后 overlay 仍为 300MB 的问题。

## 核心思路

f2fs 的 resize **必须离线**（官方 expand_root 只支持 ext4 在线 resize，这是 f2fs 的硬限制）。
因此利用 OpenWrt 自带的 **failsafe 模式**（overlay 不挂载）完成离线扩容，全程自动化：

```
控制机执行一次脚本:
  1. 自动下载编译好的工具 (tools/) 到控制机
  2. 上传到目标机 /boot (vfat 分区, failsafe 下可访问)
  3. 目标机 fdisk 扩分区 (保留起始扇区 + 专家模式改回原 PARTUUID, grub 免改)
  4. 自动重启进 failsafe
  5. failsafe: losetup 绑定 loop -> fsck -> 日志重放 -> resize.f2fs
  6. 恢复 grub 正常引导 -> 自动重启
  7. 验证 df -h /overlay = 全盘大小
```

## 使用

```sh
# 控制机安装依赖 (Debian/Ubuntu)
apt install sshpass

# 一键扩容 (默认 IP 192.168.1.1, 新装默认地址, root 空密码)
./expand-overlay.sh

# 指定 IP 和密码
./expand-overlay.sh 192.168.2.250 zz0770
```

执行后目标机自动重启 2 次，全程无需人工介入。

## 文件

| 文件 | 说明 |
|---|---|
| `expand-overlay.sh` | 控制机一键脚本 |
| `tools/f2fs-tools` | 静态编译的 f2fs-tools (含 fsck/resize/dump 多调用, musl, x86_64) |
| `tools/f2loop` | 静态编译的 loop 绑定工具 (offset 绑定, 无需 losetup) |

## 兼容性

- 目标: OpenWrt/ImmortalWrt x86_64 官方 squashfs combined 镜像 (eMMC/SATA/NVMe/虚拟机)
- 控制机: 任意 Linux (需 sshpass + curl + 能访问 github)
- 目标机**不需要**: 联网 / apk 源 / 预先安装任何软件 / 配置网络 (新装默认 192.168.1.1 即可)
- 重复执行: 自动检测 overlay > 600MB 则跳过

## 日志

- 阶段0: 目标机 `/tmp/expand-overlay.log`
- 阶段1: 目标机 `/tmp/expand-stage1.log`
- grub 备份: `/boot/grub/grub.cfg.bak-expand`

## 原理细节

1. **为什么进 failsafe**: f2fs 卷在线时 resize 会损坏 (v1.1/v1.2 实测失败), failsafe 下 overlay 不挂载, 可安全离线 resize
2. **为什么保留 PARTUUID**: fdisk 删分区重建会随机化 GPT 分区 GUID, grub 写死的 `root=PARTUUID=...` 会失配导致无法引导; 用 fdisk 专家模式 `u` 改回原值, grub 一行不用动
3. **工具为何放 /boot**: failsafe 下 `/` 是只读 squashfs, apk 装的工具不可用; /boot 是独立 vfat 分区, failsafe 下可挂载
4. **f2fs-tools 多调用**: 通过 symlink 名 (`fsck.f2fs`/`resize.f2fs`) 触发对应模式
