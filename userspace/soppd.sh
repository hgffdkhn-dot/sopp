#!/system/bin/sh
# soppSU userspace daemon. Runs as root from the init hook injected by the
# kernel; drives the lifecycle events and module mounting.
SOPP_DIR=/data/adb/s0ppSU
LOG=$SOPP_DIR/soppd.log

log() { echo "[soppd] $*" >> "$LOG"; }

case "$1" in
  post-fs-data)
    log "post-fs-data: preparing workspace"
    mkdir -p "$SOPP_DIR/modules" "$SOPP_DIR/.work" 0700
    chmod 0700 "$SOPP_DIR"
    # Systemless module overlay: mount each enabled module's system mirror.
    for module in "$SOPP_DIR"/modules/*; do
      [ -d "$module" ] || continue
      [ -f "$module/disable" ] && continue
      if [ -d "$module/system" ]; then
        mount -o bind "$module/system" /system 2>/dev/null && \
          log "mounted $(basename "$module")"
      fi
    done
    ;;
  services)
    log "services: reporting module mounted"
    # Tell the kernel the module overlay is live (enables DenyList umount).
    "$SOPP_DIR/bin/soppctl" module-mounted 2>/dev/null || true
    ;;
  boot-completed)
    log "boot-completed"
    ;;
  *)
    log "unknown action: $1"
    exit 1
    ;;
esac
