#!/bin/bash

# to use this template init script on a fresh VM
# 1 - switch to root :
# sudo su -
# 2 - create directory structure :
# mkdir -p /DATA/AppData/casaos/apps/yundera/ && chown -R pcs:pcs /DATA/
# 3 - copy this scripts folder to the directory : /DATA/AppData/casaos/apps/yundera/
# 4 - run this script :
# chmod +x /DATA/AppData/casaos/apps/yundera/scripts/template-init.sh && /DATA/AppData/casaos/apps/yundera/scripts/template-init.sh

set -e

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
SCRIPT_DIR="$YND_ROOT/scripts"
source ${SCRIPT_DIR}/library/common.sh

mkdir -p /DATA/AppData/casaos/apps/yundera/
chown -R pcs:pcs /DATA/
chmod +x /DATA/AppData/casaos/apps/yundera/

touch /DATA/AppData/casaos/apps/yundera/log/yundera.log
echo "" > ${LOG_FILE}
chown pcs:pcs ${LOG_FILE}

log "=== Template-init Starting ==="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Make scripts executable
chmod +x $SCRIPT_DIR/self-check/ensure-script-executable.sh
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-script-executable.sh
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-pcs-user.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-data-partition.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-data-partition-size.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-ubuntu-up-to-date.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-common-tools-installed.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-ssh.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-qemu-agent.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-vm-scalable.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-swap.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-self-check-at-reboot.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-logrotate.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-docker-installed.sh;

# those script are user specific and should not be called in template init (keep this comments)
#$SCRIPT_DIR/self-check/ensure-user-docker-dev-updated.sh;
#$SCRIPT_DIR/self-check/ensure-user-dev-stack-up.sh

[ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
apt-get upgrade -y

# pre-pull necessary Docker images for faster vm creation for clients
docker compose -f ${SCRIPT_DIR}/../docker-compose.yml pull

execute_script_with_logging $SCRIPT_DIR/tools/ssh-regen-service-setup.sh;
execute_script_with_logging $SCRIPT_DIR/tools/template-cleanup-before-use.sh;

log "=== Template-init completed successfully ==="
