#!/bin/sh
# ============================================================
#  OpenWrt/ImmortalWrt overlay 全自动扩容脚本 (squashfs+f2fs)
#
#  适用: x86_64 官方镜像 (squashfs combined), eMMC/SATA/NVMe/虚拟磁盘
#  原理: 与 openwrt.org expand_root 相同思路, 适配 f2fs overlay
#        1) fdisk 扩分区(保留起始扇区, 专家模式改回原 PARTUUID, grub 免改)
#        2) 写入 uci-defaults 自启脚本
#        3) 重启 -> 自动 losetup+resize.f2fs -> 自动重启 -> 完成
#
#  用法: 上传到机器后  sh expand-overlay.sh
#        或        wget -qO- http://<vps>/expand-overlay.sh | sh
#  执行后需要 2 次自动重启, 全程无需人工介入
#
#  v1.2 修复: 移除阶段1的 fsck.f2fs -f (挂载中的 f2fs 卷不可 fsck, 会损坏)
#             移除等待 30s, 立即重启
# ============================================================

set -u
LOG=/tmp/expand-overlay.log
echo "=== OpenWrt overlay 全自动扩容 v1.2 ===" | tee $LOG

# ---------- 0. 环境检测 ----------
echo "--- 0. 环境检测 ---" | tee -a $LOG

# 确认是 squashfs+f2fs overlay 布局 (与官方 x86 combined 镜像一致)
if ! grep -q "squashfs" /proc/mounts; then
    echo "ERROR: 未检测到 squashfs 只读根 (/rom), 本脚本仅支持 squashfs+f2fs 官方镜像布局" | tee -a $LOG
    exit 1
fi

# 找 /overlay 挂载的源设备 (mountinfo: $5=mountpoint, $9=source)
OVERLAY_SRC="$(awk '$5=="/overlay"{print $9}' /proc/self/mountinfo)"
echo "overlay source: $OVERLAY_SRC" | tee -a $LOG
[ -z "$OVERLAY_SRC" ] && { echo "ERROR: 未找到 /overlay 挂载源" | tee -a $LOG; exit 1; }
case "$OVERLAY_SRC" in
    /dev/loop*) LOOP_DEV="$OVERLAY_SRC" ;;
    *) echo "WARN: /overlay 不在 loop 上 ($OVERLAY_SRC), 可能是 ext4 布局, 本脚本不适用" | tee -a $LOG; exit 1 ;;
esac

# 找 root 分区块设备 (mountinfo: /rom 行的 major:minor)
ROOT_MAJMIN="$(awk '$5=="/rom"{print $3}' /proc/self/mountinfo)"
ROOT_SRC="$(awk '$5=="/rom"{print $9}' /proc/self/mountinfo)"
echo "rom mount: majmin=$ROOT_MAJMIN src=$ROOT_SRC" | tee -a $LOG

# 从 sysfs 解析真实块设备路径
ROOT_SYS="$(readlink -f /sys/dev/block/$ROOT_MAJMIN 2>/dev/null)"
ROOT_DEV="/dev/${ROOT_SYS##*/}"               # /dev/mmcblk0p2
ROOT_DISK="/dev/$(basename "${ROOT_SYS%/*}")"  # /dev/mmcblk0
ROOT_PART="${ROOT_DEV##*[^0-9]}"              # 2
echo "root: $ROOT_DEV (disk=$ROOT_DISK part=$ROOT_PART)" | tee -a $LOG
[ -b "$ROOT_DEV" ] || { echo "ERROR: 无法解析 root 设备 $ROOT_DEV" | tee -a $LOG; exit 1; }

# f2fs 卷在 root 分区内的偏移 (字节), 从 loop 设备读
OFFSET="$(cat /sys/block/${LOOP_DEV#/dev/}/loop/offset 2>/dev/null)"
echo "f2fs offset: $OFFSET bytes" | tee -a $LOG
[ -z "$OFFSET" ] && { echo "ERROR: 无法读取 f2fs offset" | tee -a $LOG; exit 1; }

# 当前 grub 里的 PARTUUID (必须保留, 否则引导失败)
OLD_PARTUUID="$(grep -o 'PARTUUID=[^ ]*' /boot/grub/grub.cfg 2>/dev/null | head -1 | cut -d= -f2)"
echo "current PARTUUID: $OLD_PARTUUID" | tee -a $LOG
[ -z "$OLD_PARTUUID" ] && { echo "ERROR: 无法从 grub.cfg 读取 PARTUUID" | tee -a $LOG; exit 1; }

# 起始扇区 (删除重建时必须保持不变)
START_SECTOR="$(fdisk -l "$ROOT_DISK" 2>/dev/null | awk -v d="$ROOT_DEV" '$1==d{print $2}')"
echo "root part start sector: $START_SECTOR" | tee -a $LOG
[ -z "$START_SECTOR" ] && { echo "ERROR: 无法读取起始扇区" | tee -a $LOG; exit 1; }

# 磁盘总扇区 (GPT 会预留末尾)
DISK_SECTORS="$(cat /sys/class/block/${ROOT_DISK#/dev/}/size)"
echo "disk sectors: $DISK_SECTORS" | tee -a $LOG

# 已经扩过了? (f2fs 卷大小 > 600MB 说明已完成, 官方默认 300M)
CUR_OVERLAY_KB="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $2}')"
if [ "${CUR_OVERLAY_KB:-0}" -gt 600000 ]; then
    echo "overlay 已是 ${CUR_OVERLAY_KB} KB, 无需扩容, 退出" | tee -a $LOG
    exit 0
fi

# ---------- 1. 安装依赖 ----------
echo "--- 1. 安装依赖 (f2fs-tools losetup) ---" | tee -a $LOG
if ! command -v resize.f2fs >/dev/null 2>&1 || ! command -v losetup >/dev/null 2>&1; then
    apk update >>$LOG 2>&1 || { echo "ERROR: apk update 失败" | tee -a $LOG; exit 1; }
    apk add f2fs-tools losetup >>$LOG 2>&1 || { echo "ERROR: apk add f2fs-tools losetup 失败" | tee -a $LOG; exit 1; }
fi
command -v resize.f2fs >/dev/null 2>&1 || { echo "ERROR: resize.f2fs 不可用" | tee -a $LOG; exit 1; }
command -v losetup >/dev/null 2>&1 || { echo "ERROR: losetup 不可用" | tee -a $LOG; exit 1; }
echo "依赖就绪: $(command -v resize.f2fs), $(command -v losetup)" | tee -a $LOG

# ---------- 2. 备份 grub ----------
echo "--- 2. 备份 grub.cfg ---" | tee -a $LOG
cp /boot/grub/grub.cfg /boot/grub/grub.cfg.bak-expand 2>/dev/null
echo "备份: /boot/grub/grub.cfg.bak-expand" | tee -a $LOG

# ---------- 3. fdisk 扩分区 (保留起始扇区 + 改回原 GUID) ----------
echo "--- 3. fdisk 扩分区 p$ROOT_PART ---" | tee -a $LOG
{
    echo "d"
    echo "$ROOT_PART"
    echo "n"
    echo "$ROOT_PART"
    echo "$START_SECTOR"
    echo ""                       # 默认到 GPT 允许的末尾
    echo "x"
    echo "u"
    echo "$ROOT_PART"
    echo "$OLD_PARTUUID"
    echo "r"
    echo "w"
} | fdisk "$ROOT_DISK" >>$LOG 2>&1
RC=$?
[ $RC -ne 0 ] && { echo "ERROR: fdisk 失败 (rc=$RC)" | tee -a $LOG; exit 1; }
echo "分区已扩展" | tee -a $LOG
fdisk -l "$ROOT_DISK" 2>/dev/null | grep "$ROOT_DEV" | tee -a $LOG

# ---------- 4. 写 uci-defaults 自动扩容脚本 (阶段1, 动态检测) ----------
echo "--- 4. 写入 uci-defaults 自动扩容脚本 ---" | tee -a $LOG
mkdir -p /etc/uci-defaults
cat > /etc/uci-defaults/80-rootfs-resize <<'STAGE1'
#!/bin/sh
# 阶段1: 重启后由 uci-defaults 自动执行 (开机时 uci_apply_defaults 运行一次)
# 动态检测设备, 不依赖硬编码路径
# v1.2: 移除 fsck.f2fs -f (挂载中的卷不可 fsck); 仅 mount/umount 重放日志 + resize
LOG=/tmp/expand-stage1.log
echo "=== [stage1] resize overlay f2fs ===" > $LOG

# 已完成标记则跳过
[ -e /etc/rootfs-resize-done ] && { echo "already done" >> $LOG; exit 1; }

OVERLAY_SRC="$(awk '$5=="/overlay"{print $9}' /proc/self/mountinfo)"
ROOT_MAJMIN="$(awk '$5=="/rom"{print $3}' /proc/self/mountinfo)"
ROOT_SYS="$(readlink -f /sys/dev/block/$ROOT_MAJMIN 2>/dev/null)"
ROOT_DEV="/dev/${ROOT_SYS##*/}"
OFFSET="$(cat /sys/block/${OVERLAY_SRC#/dev/}/loop/offset 2>/dev/null)"

echo "root=$ROOT_DEV overlay_src=$OVERLAY_SRC offset=$OFFSET" >> $LOG

NEW_LOOP="$(losetup -f)"
echo "new loop: $NEW_LOOP" >> $LOG
losetup -o "$OFFSET" "$NEW_LOOP" "$ROOT_DEV" || { echo "losetup failed" >> $LOG; exit 1; }
NEW_SIZE="$(cat /sys/block/${NEW_LOOP#/dev/}/size)"
echo "new loop size: $NEW_SIZE sectors" >> $LOG

# 防御: 新 loop 必须大于旧卷 (290M=594176 sectors), 否则说明分区没扩成功
if [ "${NEW_SIZE:-0}" -lt 1000000 ]; then
    echo "ERROR: loop 太小 ($NEW_SIZE), 分区可能未扩大, 中止" >> $LOG
    losetup -d "$NEW_LOOP" 2>/dev/null
    exit 1
fi

# mount/umount 重放日志 (unclean 时 resize 会拒绝; 挂载失败可容忍, 继续尝试 resize)
mkdir -p /mnt/expand
if mount -t f2fs "$NEW_LOOP" /mnt/expand >> $LOG 2>&1; then
    sync
    umount /mnt/expand >> $LOG 2>&1
    echo "log replay OK" >> $LOG
else
    echo "log replay skipped (mount failed, 继续)" >> $LOG
fi

# resize 到 loop 设备满
resize.f2fs -f "$NEW_LOOP" >> $LOG 2>&1
RC=$?
echo "resize.f2fs rc=$RC" >> $LOG
losetup -d "$NEW_LOOP" 2>/dev/null

if [ $RC -ne 0 ]; then
    echo "RESIZE FAILED (rc=$RC), 保留现场供排查" >> $LOG
    exit 1
fi

touch /etc/rootfs-resize-done
echo "扩容完成, 立即重启" >> $LOG
sync
reboot
exit 1
STAGE1
chmod +x /etc/uci-defaults/80-rootfs-resize
echo "已写入 /etc/uci-defaults/80-rootfs-resize" | tee -a $LOG

# ---------- 5. 触发重启 ----------
echo "--- 5. 分区已扩, 立即重启进入阶段1 ---" | tee -a $LOG
echo "重启后无需任何操作, 将自动完成 f2fs 扩容并再次重启" | tee -a $LOG
sync
reboot
