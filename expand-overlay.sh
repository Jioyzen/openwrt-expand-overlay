#!/bin/sh
# ============================================================
#  OpenWrt/ImmortalWrt overlay 全自动扩容 - 控制机一键版
#
#  用法:  ./expand-overlay.sh [目标IP] [root密码]
#  例:    ./expand-overlay.sh 192.168.1.1
#         ./expand-overlay.sh 192.168.2.250 zz0770
#
#  前置:  控制机需安装 sshpass; 目标机为 x86_64 squashfs+f2fs 官方镜像
#         目标机只需可达 IP(默认192.168.1.1, 新装默认), 无需配置网络/apk源
#
#  流程:  1) 自动下载编译好的工具(f2fs-tools/f2loop)到本机
#         2) 上传工具到目标机 /boot (vfat, failsafe下可用)
#         3) 目标机: fdisk 扩分区(保留起始扇区+原PARTUUID) + grub 默认进 failsafe
#         4) 自动重启 -> failsafe (overlay未挂载, 可安全离线 resize)
#         5) 目标机: losetup + fsck + 日志重放 + resize.f2fs
#         6) 恢复 grub 正常引导 -> 自动重启 -> 扩容完成
#
#  原理:  f2fs 的 resize 必须离线(官方 expand_root 仅支持 ext4 在线 resize),
#         failsafe 模式跳过 overlay 挂载, 是唯一可靠的离线扩容路径
# ============================================================

set -u
VERSION="2.0"

TARGET_IP="${1:-192.168.1.1}"
TARGET_PASS="${2:-}"
GH_BASE="https://raw.githubusercontent.com/Jioyzen/openwrt-expand-overlay/main"
TOOL_DIR="${TOOL_DIR:-/tmp/openwrt-expand-tools}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"

echo "=== OpenWrt overlay 全自动扩容 (控制机版 v$VERSION) ==="
echo "目标: $TARGET_IP  密码: ${TARGET_PASS:+已设置}${TARGET_PASS:-空(新装默认)}"

# ---------- 0. 控制机前置检查 ----------
command -v sshpass >/dev/null 2>&1 || { echo "ERROR: 控制机缺少 sshpass (apt install sshpass)"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: 控制机缺少 curl"; exit 1; }

# ---------- 1. 下载工具 ----------
echo "--- [1] 下载工具到控制机 ---"
mkdir -p "$TOOL_DIR"
for f in f2fs-tools f2loop; do
    if [ ! -f "$TOOL_DIR/$f" ]; then
        echo "下载 $f ..."
        curl -sL --max-time 60 -o "$TOOL_DIR/$f" "$GH_BASE/tools/$f" || { echo "ERROR: 下载 $f 失败"; exit 1; }
        chmod +x "$TOOL_DIR/$f"
    fi
done
echo "工具就绪: $(ls -la $TOOL_DIR/f2fs-tools $TOOL_DIR/f2loop | awk '{print $NF, $5"B"}')"

# ---------- 2. 上传工具到目标机 /boot ----------
echo "--- [2] 上传工具到目标机 /boot/f2fs/ ---"
ssh_run() { sshpass -p "$TARGET_PASS" ssh $SSH_OPTS "root@$TARGET_IP" "$@"; }
ssh_run "mkdir -p /boot/f2fs" 2>/dev/null || { echo "ERROR: 无法连接目标机 $TARGET_IP (密码是否正确?)"; exit 1; }
cat "$TOOL_DIR/f2fs-tools" | ssh_run "cat > /boot/f2fs/f2fs-tools && chmod +x /boot/f2fs/f2fs-tools"
cat "$TOOL_DIR/f2loop"     | ssh_run "cat > /boot/f2fs/f2loop && chmod +x /boot/f2fs/f2loop"
ssh_run "ls -la /boot/f2fs/" || exit 1

# ---------- 3. 阶段0: 扩分区 + 配置 failsafe ----------
echo "--- [3] 目标机: 检测 + 扩分区 + 配置 failsafe ---"
ssh_run 'sh -s' <<'STAGE0' || true
#!/bin/sh
LOG=/tmp/expand-overlay.log
echo "=== stage0 $(date) ===" > $LOG

# 已扩容则跳过
CUR=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $2}')
if [ "${CUR:-0}" -gt 600000 ]; then
    echo "overlay 已是 ${CUR}KB, 无需扩容" | tee -a $LOG
    exit 0
fi
echo "overlay 当前: ${CUR}KB" | tee -a $LOG

# 检测: /overlay 挂载源 + /rom 设备 + offset + PARTUUID + 起始扇区
OVERLAY_SRC=$(awk '$5=="/overlay"{print $9}' /proc/self/mountinfo)
ROOT_MAJMIN=$(awk '$5=="/rom"{print $3}' /proc/self/mountinfo)
ROOT_SYS=$(readlink -f /sys/dev/block/$ROOT_MAJMIN 2>/dev/null)
ROOT_DEV="/dev/${ROOT_SYS##*/}"
ROOT_DISK="/dev/$(basename "${ROOT_SYS%/*}")"
ROOT_PART="${ROOT_DEV##*[^0-9]}"
OFFSET=$(cat /sys/block/${OVERLAY_SRC#/dev/}/loop/offset 2>/dev/null)
OLD_PARTUUID=$(grep -o 'PARTUUID=[^ ]*' /boot/grub/grub.cfg 2>/dev/null | head -1 | cut -d= -f2)
START_SECTOR=$(fdisk -l "$ROOT_DISK" 2>/dev/null | awk -v d="$ROOT_DEV" '$1==d{print $2}')

echo "root=$ROOT_DEV disk=$ROOT_DISK part=$ROOT_PART offset=$OFFSET start=$START_SECTOR uuid=$OLD_PARTUUID" | tee -a $LOG
[ -n "$OFFSET" ] && [ -n "$OLD_PARTUUID" ] && [ -n "$START_SECTOR" ] || { echo "ERROR: 检测失败" | tee -a $LOG; exit 1; }

# 备份 grub
cp /boot/grub/grub.cfg /boot/grub/grub.cfg.bak-expand 2>/dev/null

# fdisk 扩分区: 删 p2 重建(保留起始扇区) + 专家模式改回原 PARTUUID
echo "--- fdisk 扩分区 ---" | tee -a $LOG
{
    echo "d"; echo "$ROOT_PART"
    echo "n"; echo "$ROOT_PART"; echo "$START_SECTOR"; echo ""
    echo "x"; echo "u"; echo "$ROOT_PART"; echo "$OLD_PARTUUID"; echo "r"
    echo "w"
} | fdisk "$ROOT_DISK" >>$LOG 2>&1
RC=$?
[ $RC -ne 0 ] && { echo "ERROR: fdisk 失败 rc=$RC" | tee -a $LOG; exit 1; }
fdisk -l "$ROOT_DISK" 2>/dev/null | grep "$ROOT_DEV" | tee -a $LOG

# grub 默认进 failsafe (default=1)
sed -i 's/^set default="0"/set default="1"/' /boot/grub/grub.cfg
grep "^set default" /boot/grub/grub.cfg | tee -a $LOG

echo "--- 分区已扩, 重启进 failsafe ---" | tee -a $LOG
sync
reboot
STAGE0

# ---------- 4. 等待 failsafe ----------
echo "--- [4] 等待 failsafe 上线 ($TARGET_IP) ---"
FS_UP=""
for i in $(seq 1 36); do
    sleep 5
    if timeout 6 sshpass -p "" ssh $SSH_OPTS root@$TARGET_IP \
        'grep -q "failsafe=" /proc/cmdline && echo FS' 2>/dev/null | grep -q FS; then
        echo "failsafe 上线 (~$((i*5))s)"
        FS_UP=1
        break
    fi
done
[ -n "$FS_UP" ] || { echo "ERROR: failsafe 等待超时, 检查目标机 (可能 grub 未进入 failsafe)"; exit 1; }

# ---------- 5. 阶段1: failsafe 离线扩容 ----------
echo "--- [5] failsafe: 离线 fsck + resize.f2fs ---"
sshpass -p "" ssh $SSH_OPTS root@$TARGET_IP 'sh -s' <<'STAGE1' || true
#!/bin/sh
LOG=/tmp/expand-stage1.log
echo "=== stage1 $(date) ===" > $LOG
B=/tmp/boot/boot/f2fs

# 挂载 /boot (failsafe 下 / 是只读 squashfs, 挂载点用 /tmp)
mkdir -p /tmp/boot
mount -t vfat -o fmask=0000,dmask=0000,exec /dev/mmcblk0p1 /tmp/boot >>$LOG 2>&1
echo "boot mounted: $(ls $B/ 2>/dev/null)" | tee -a $LOG

# 动态检测
OVERLAY_SRC=$(awk '$5=="/overlay"{print $9}' /proc/self/mountinfo 2>/dev/null)
ROOT_MAJMIN=$(awk '$5=="/rom"{print $3}' /proc/self/mountinfo)
ROOT_SYS=$(readlink -f /sys/dev/block/$ROOT_MAJMIN 2>/dev/null)
ROOT_DEV="/dev/${ROOT_SYS##*/}"
OFFSET=$(cat /sys/block/${OVERLAY_SRC#/dev/}/loop/offset 2>/dev/null)
echo "root=$ROOT_DEV overlay_src=$OVERLAY_SRC offset=$OFFSET" | tee -a $LOG

# 绑定 loop -> p2+offset (离线, loop 空闲)
$B/f2loop "$ROOT_DEV" "$OFFSET" /dev/loop0 2>&1 | tee -a $LOG
echo "loop0 size: $(cat /sys/block/loop0/size) sectors" | tee -a $LOG
[ "$(cat /sys/block/loop0/size 2>/dev/null)" -gt 1000000 ] || { echo "ERROR: loop0 太小" | tee -a $LOG; exit 1; }

# 多调用工具: 通过 symlink 触发模式
ln -sf $B/f2fs-tools /tmp/fsck.f2fs
ln -sf $B/f2fs-tools /tmp/resize.f2fs

# fsck (离线, 安全)
echo "--- fsck ---" | tee -a $LOG
/tmp/fsck.f2fs -f /dev/loop0 >>$LOG 2>&1
echo "fsck rc=$?" | tee -a $LOG

# mount/umount 重放日志
echo "--- 日志重放 ---" | tee -a $LOG
mkdir -p /tmp/mnt
mount -t f2fs /dev/loop0 /tmp/mnt >>$LOG 2>&1 && { sync; umount /tmp/mnt >>$LOG 2>&1; echo "replay OK" | tee -a $LOG; } || echo "replay skipped" | tee -a $LOG

# resize (自动回答 y)
echo "--- resize ---" | tee -a $LOG
echo y | /tmp/resize.f2fs -f /dev/loop0 >>$LOG 2>&1
RC=$?
echo "resize rc=$RC" | tee -a $LOG
[ $RC -ne 0 ] && { echo "ERROR: resize 失败" | tee -a $LOG; exit 1; }

# 验证
mkdir -p /tmp/mnt2
mount -t f2fs /dev/loop0 /tmp/mnt2 >>$LOG 2>&1 && { df -h /tmp/mnt2 | tee -a $LOG; umount /tmp/mnt2; }

# 恢复 grub 正常引导 (注意: vfat 根下有 boot/ 子目录)
echo "--- 恢复 grub ---" | tee -a $LOG
sed -i 's/^set default="1"/set default="0"/' /tmp/boot/boot/grub/grub.cfg
grep "^set default" /tmp/boot/boot/grub/grub.cfg | tee -a $LOG

# 清理 + 重启
$B/f2loop --clear /dev/loop0 2>/dev/null
sync
sleep 1
reboot -f
STAGE1

# ---------- 6. 等待正常启动 + 验证 ----------
echo "--- [6] 等待正常系统上线 ---"
NB_UP=""
for i in $(seq 1 36); do
    sleep 5
    R=$(timeout 6 sshpass -p "$TARGET_PASS" ssh $SSH_OPTS root@$TARGET_IP \
        'grep -q "failsafe=" /proc/cmdline && echo FS || echo NB' 2>/dev/null)
    if [ "$R" = "NB" ]; then
        echo "正常系统上线 (~$((i*5))s)"
        NB_UP=1
        break
    fi
done
[ -n "$NB_UP" ] || { echo "ERROR: 正常系统等待超时"; exit 1; }

# 验证
echo "--- [7] 验证 ---"
sshpass -p "$TARGET_PASS" ssh $SSH_OPTS root@$TARGET_IP 'df -h / /overlay; echo; echo "grub: $(grep "^set default" /boot/grub/grub.cfg)"; echo "loop0: $(cat /sys/block/loop0/size) sectors"'

echo
echo "=== 扩容完成 ==="
