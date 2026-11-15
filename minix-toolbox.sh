#!/bin/bash

# CONFIG

# minix image source
MINIX_IMAGE_URL="http://www.ia.pw.edu.pl/~tkruk/edu/soi.b/lab/minix/minix203.img"

# tool paths
WORKDIR="."
TOOLBOX_SUBDIR="$WORKDIR/.minix-toolbox"
MINIX_SOURCES_DIR="$WORKDIR/minix_sources"
MINIX_USR_MOUNT_DIR="$TOOLBOX_SUBDIR/mnt_usr"
MINIX_ROOT_MOUNT_DIR="$TOOLBOX_SUBDIR/mnt_root"
MINIX_BASE_IMAGE_PATH="$TOOLBOX_SUBDIR/minix.base.img"
MINIX_WORK_IMAGE_PATH="$TOOLBOX_SUBDIR/minix.work.img"

# qemu minix communication
HOST=127.0.0.1
QEMU_MON_PORT=4001
MINIX_TTY00_PORT=4002
MINIX_TTY01_PORT=4003

# END CONFIG

# common utilities

SCRIPT_VERSION="v0.1.3"
SCRIPT_NAME=$(basename "$0")

echo_err() {
  echo "$SCRIPT_NAME: error: $1" 1>&2
}

# minix emulation control

# stream 3 - QEMU Monitor
# stream 4 - MINIX tty00 (with terminal running)
# stream 5 - MINIX tty01

minix_cleanup_streams() {
  exec 3<&- 3>&- || true
  exec 4<&- 4>&- || true
  exec 5<&- 5>&- || true
}

minix_create_streams() {
  local error=""
  echo "Connecting to minix terminal and QEMU monitor."

  exec 3<>/dev/tcp/"$HOST"/"$QEMU_MON_PORT" ||
    error="Failed to connect to QEMU Monitor server on ${HOST}:${QEMU_MON_PORT}"

  exec 4<>/dev/tcp/"$HOST"/"$MINIX_TTY00_PORT" ||
    error="Failed to connect to minix tty00 server on ${HOST}:${MINIX_TTY00_PORT}"

  exec 5<>/dev/tcp/"$HOST"/"$MINIX_TTY01_PORT" ||
    error="Failed to connect to minix tty01 server on ${HOST}:${MINIX_TTY01_PORT}"

  if [ -n "$error" ]; then
    echo_err "$error"
    return 1
  fi
  return 0
}

minix_wait_for_terminal() {
  local retries=5
  echo "Waiting for minix terminal to start."

  while [ $retries -ge 0 ]; do
    if IFS= read -r -d '' -n 1 -t 1 char <&4; then
      if [ "$char" = "#" ]; then
        return 0
      fi
    fi

    sleep 1
    ((retries--))
    echo "."
  done

  echo_err "timeout while connecting to minix terminal"
  return 1
}

minix_start_emulation() {
  # $1 - minix image path
  # $2 - minix emul pid ref
  # $3 - should use display? (0/1)
  local -n pid=$2
  local display_mode=$( ([ "$3" == 1 ] && echo 'gtk') || echo 'none' )

  qemu-system-i386 \
    -display "$display_mode" \
    -drive format=raw,file="$1" \
    -serial tcp:"$HOST":"$MINIX_TTY00_PORT",server,nowait \
    -serial tcp:"$HOST":"$MINIX_TTY01_PORT",server,nowait \
    -monitor tcp:"$HOST":"$QEMU_MON_PORT",server,nowait \
    2>&1 &

  pid=$!

  sleep 0.5
  # log error if emulation terminated immediately due to an error
  if ! kill -0 "$pid" 2>/dev/null; then
    echo_err "minix emulation failed to start"
    return 1
  fi
  echo "minix Emulation has started (pid=$pid)"
  sleep 3
  if ! minix_create_streams; then
    kill $pid
    kill -9 $pid
    return 1
  fi

  echo "Booting minix"
  echo "sendkey equal" >&3 # qemu monitor: send =
}

minix_finish_emulation() {
  # $1 - qemu emulation pid
  echo "Terminating minix emulation..."
  echo "shutdown" >&4
  sleep 5
  echo "quit" >&3 # qemu monitor: quit

  # kill emulation if it doesn't finish
  sleep 0.5
  if kill -0 $1 2>/dev/null; then
    sleep 3
    kill -9 $1 2>/dev/null
  fi

  minix_cleanup_streams
  echo "Minix emulation finished"
}

# minix command executing

minix_exec_and_stream() {
  # $1 - command to exec
  trap "$(set +o | grep errexit)" RETURN && set +e  # disable exit on err
  local marker="__DONE_MARKER__"
  local separator="--------------------------------"
  local timeout=300

  echo "( $1 ) 2>/dev/tty01 >/dev/tty01; echo '$marker'" >&4
  (
    while read -r -t "$timeout" line <&4; do
      if [ "${line%$'\r'}" == "$marker" ]; then
        break;
      fi
    done
  ) &
  local term_scanner_pid=$!
  local running=1
  local write_seps=0

  while [ $running == 1 ]; do
    read -r -t 1 line <&5 2>/dev/null
    if ! [ -z "$line" ]; then
      # write separator if it was first line streamed from the command
      [ "$write_seps" == 0 ] && write_seps=1 && echo "$separator"
      echo "$line"
    fi

    if ! kill -0 "$term_scanner_pid" 2>/dev/null; then
      wait "$term_scanner_pid"
      local status=$?
      if [ $status != 0 ]; then
        echo_err "an error was encountered while streaming command output from minix"
      fi
      running=0
    fi
  done
  [ "$write_seps" != 0 ] && echo "$separator"

  return 0
}

# minix images mounting

minix_read_image_subpartitions_info() {
  trap "$(set +o | grep errexit); trap - ERR" RETURN && set -e  # exit on err
  local img_path=$1
  local -n root_offs=$2 root_siz=$3 usr_offs=$4 usr_siz=$5

  trap 'echo_err "Failed to read minix subpartitions from the image file"; return 1;' ERR

  if ! [ -f "$img_path" ]; then
    echo_err "minix image was not found at $img_path"
    false # finish with err
  fi

  local mbr_sig=$(od -An -j 510 -N 2 -t x2 --endian big "$img_path" | tr -d ' ')
  if [ $mbr_sig != "55aa" ]; then
    echo_err "minix image file has invalid MBR signature"
    false # finish with err
  fi

  # read partition 0 offset
  local p0_sector=$(od -An -j 454 -N 4 -t u4 "$img_path")
  local p0_offset=$((p0_sector * 512))

  # read minix subpartition offsets
  local minix_subpart_base=$((p0_offset + 446))
  local root_sector=$(od -An -j $((minix_subpart_base + 8)) -N 4 -t u4 "$img_path")
  local root_size_sec=$(od -An -j $((minix_subpart_base + 12)) -N 4 -t u4 "$img_path")
  local usr_sector=$(od -An -j $((minix_subpart_base + 40)) -N 4 -t u4 "$img_path")
  local usr_size_sec=$(od -An -j $((minix_subpart_base + 44)) -N 4 -t u4 "$img_path")

  root_offs=$(($root_sector * 512))
  root_siz=$(($root_size_sec * 512))
  usr_offs=$(($usr_sector * 512))
  usr_siz=$(($usr_size_sec * 512))

  return 0
}

minix_mount_img() {
  # $1 - image path
  trap "$(set +o | grep errexit); trap - ERR" RETURN && set -e  # exit on err
  local mounts_failed=0
  local root_offset root_size usr_offset usr_size

  minix_read_image_subpartitions_info "$1" root_offset root_size usr_offset usr_size

  trap \
    $'minix_umount_img 2>/dev/null; echo_err "Failed to mount the minix image. Make sure the image isn\'t already mounted."; return 1;' \
    ERR
  mount -t minix -o loop,offset="$root_offset",sizelimit="$root_size" "$1" "$MINIX_ROOT_MOUNT_DIR"
  mount -t minix -o loop,offset="$usr_offset",sizelimit="$usr_size" "$1" "$MINIX_USR_MOUNT_DIR"

  cat <<EOF
Mounted minix image partitions:
/        offset: $root_offset, size: $root_size, mounted at: "$MINIX_ROOT_MOUNT_DIR"
/usr     offset: $usr_offset, size: $usr_size, mounted at: "$MINIX_USR_MOUNT_DIR"
EOF

  return 0
}

minix_umount_img() {
  echo "Unmounting minix image partitions"

  sync
  umount "$MINIX_USR_MOUNT_DIR"
  umount "$MINIX_ROOT_MOUNT_DIR"
}

# minix image download

minix_download_base_image() {
  echo "Downloading minix image..."
  wget -O "$MINIX_BASE_IMAGE_PATH" "$MINIX_IMAGE_URL" ||
    {
      echo_err "Failed to download minix image from URL provided in config."
      return 1
    }
  return 0
}

# toolbox common functions

toolbox_init_dirs() {
  rm -r "$TOOLBOX_SUBDIR"
  mkdir "$TOOLBOX_SUBDIR" "$MINIX_USR_MOUNT_DIR" "$MINIX_ROOT_MOUNT_DIR" ||
    {
      echo_err "Failed to prepare $SCRIPT_NAME subdirectories."
      return 1
    }
  return 0
}

toolbox_copy_source_dirs_from_mounted_image() {
  # $1 image path
  trap "$(set +o | grep errexit); trap - ERR" RETURN && set -e  # exit on err
  trap 'return 1;' ERR

  rm -rf "$MINIX_SOURCES_DIR"
  mkdir "$MINIX_SOURCES_DIR"

  cp -rf "$MINIX_USR_MOUNT_DIR/src/." "$MINIX_SOURCES_DIR/src"
  cp -rf "$MINIX_USR_MOUNT_DIR/include/." "$MINIX_SOURCES_DIR/include"
}

toolbox_workspace_check() {
  if [ -d "$TOOLBOX_SUBDIR" ]; then
    return 0
  fi
  echo_err "This command needs to be run inside a toolkit workspace. Use '$SCRIPT_NAME setup' to initialize workspace in the current workdir."
  return 1
}

# subprograms

prog_img_setup() {
  # $1 - only rebuild image
  trap "$(set +o | grep errexit); trap - ERR" RETURN && set -e  # exit on err

  if [ "$1" == 0 ]; then
    echo "Setting up workdir for minix..."
    toolbox_init_dirs
  else
    echo "Rebuilding base image..."
  fi
  minix_download_base_image

  minix_mount_img "$MINIX_BASE_IMAGE_PATH"
  trap 'minix_umount_img; return 1;' ERR

  # enable 2 rs232 serial ports in config.h
  sed -i 's/^#define[ \t]\+NR_RS_LINES[ \t]\+[0-9]\+/#define	NR_RS_LINES        2/' "${MINIX_USR_MOUNT_DIR}/include/minix/config.h"

  # create bootstrap script
  echo "Creating bootstrap script."
  cat <<EOF >"${MINIX_USR_MOUNT_DIR}/etc/bootstrap.sh"
#!/bin/sh
rm build.log
cd /usr/src/tools
make hdboot > /bootstrap.log 2>&1
if [ \$? = 0 ]; then
  echo "BUILD_SUCCESS" >> /bootstrap.log
else
  echo "BUILD_FAILURE" >> /bootstrap.log
fi

rm -f /usr/etc/bootstrap.sh
shutdown
EOF
  chmod +x "${MINIX_USR_MOUNT_DIR}/etc/bootstrap.sh"

  # add bootstrap.sh running to /usr/etc/rc start script
  echo "Adding bootstrap script to /usr/etc/rc"
  if ! grep -q "bootstrap.sh" "${MINIX_USR_MOUNT_DIR}/etc/rc"; then
    cat <<EOF >>"${MINIX_USR_MOUNT_DIR}/etc/rc"
echo "Checking bootstrap"
if [ -f /usr/etc/bootstrap.sh ]; then
    echo "Running bootstrap"
    sh /usr/etc/bootstrap.sh
fi
EOF
  fi

  trap - ERR
  minix_umount_img

  echo "Recompiling kernel"

  local emul_pid
  minix_start_emulation "$MINIX_BASE_IMAGE_PATH" emul_pid
  trap 'minix_finish_emulation "$emul_pid"; return 1;' ERR

  local timeout=100

  echo "Starting minix recompilation and waiting $timeout seconds."
  echo "If the recompilation won't manage to finish in this time, try increasing this value."
  sleep $timeout

  trap - ERR
  minix_finish_emulation "$emul_pid"

  minix_mount_img "$MINIX_BASE_IMAGE_PATH"
  trap 'minix_umount_img; return 1;' ERR

  # read recompilation status from logs
  local build_status=2 # 0 - success, 1 - error, 2 - unfinished
  if [ -f "${MINIX_ROOT_MOUNT_DIR}/bootstrap.log" ]; then
    local status=$(sed -n '${s/\r$//;p}' "${MINIX_ROOT_MOUNT_DIR}/bootstrap.log")
    if [ "$status" = "BUILD_SUCCESS" ]; then
      build_status=0
    elif [ "$status" = "BUILD_FAILURE" ]; then
      build_status=1
    fi
  fi

  if [ $build_status = 0 ]; then
    echo "Minix recompilation completed successfully. The image is now ready to be used with minix-toolbox automation."
  elif [ $build_status = 1 ]; then
    echo_err "Something went wrong while recompiling minix:"
    cat "${MINIX_ROOT_MOUNT_DIR}/bootstrap.log"
    false # produce error to clean up and finish
  else
    echo_err "Minix recompilation wasn't completed. Try increasing build timeout."
    false # produce error to clean up and finish
  fi

  # modify ttytab to run terminal at tty00 serial
  sed -i 's/^tty00.*$/tty00\t\tvt100\t\t"\/bin\/sh"/' "${MINIX_ROOT_MOUNT_DIR}/etc/ttytab"

  # copy minix source files
  if [ "$1" == 0 ]; then
    echo "Copying source files from minix image"
    toolbox_copy_source_dirs_from_mounted_image
  fi

  trap - ERR
  minix_umount_img

  # copy base image as work image
  cp "$MINIX_BASE_IMAGE_PATH" "$MINIX_WORK_IMAGE_PATH"

  echo "Setup completed successfully"
}

prog_build() {
  echo "Starting minix recompilation..."

  prog_push_sources

  local emul_pid
  minix_start_emulation "$MINIX_WORK_IMAGE_PATH" emul_pid

  if minix_wait_for_terminal; then
    set +o | grep errexit
    echo "Executing build command."
    trap 'trap - ERR; echo "It finished!"' ERR
    minix_exec_and_stream "cd /usr/src/tools && make clean && make hdboot; sleep 10"
  fi

  minix_finish_emulation "$emul_pid"
}

prog_run() {
  # $1 - c/sh script path
  # $2 - 0/1 flag if emulation should use display
  trap "$(set +o | grep errexit); trap - ERR" RETURN && set -e  # exit on err

  if ! [ -f "$1" ]; then
    echo_err "'$1' does not exist or is not a file."
    return 1
  fi

  local filename=`basename "$1"`
  local is_c_script=0
  case "$filename" in
  *.c)
    is_c_script=1
    ;;
  esac

  # copy script to minix image
  minix_mount_img "$MINIX_WORK_IMAGE_PATH"
  trap 'minix_umount_img; return 1;' ERR

  echo "Sending script to minix"
  local dir_path="$MINIX_USR_MOUNT_DIR/run_script"
  rm -rf "$dir_path"
  mkdir "$dir_path"
  cp "$1" "$dir_path"
  chown -R 0:0 "$MINIX_USR_MOUNT_DIR/run_script"

  minix_umount_img
  trap - ERR

  local emul_pid
  minix_start_emulation "$MINIX_WORK_IMAGE_PATH" emul_pid "$2"
  trap 'minix_finish_emulation; return 1;' ERR

  # run script (after compilation if it is a C file)
  if minix_wait_for_terminal; then
    local marker='__RUN_MARKER__';
    if [ $is_c_script == 1 ]; then
      local out_prog_name="${filename%.*}"
      echo "Compiling C script..."
      minix_exec_and_stream "cd /usr/run_script/ && cc -o '$out_prog_name' '$filename'"
      filename="$out_prog_name"
    fi

    echo "Running script..."
    minix_exec_and_stream "cd /usr/run_script/ && chmod +x '$filename' && './$filename'"

    echo "Script execution finished."
  fi

  trap - ERR
  minix_finish_emulation "$emul_pid"
}

prog_push_sources() {
  trap "$(set +o | grep errexit); trap - ERR" RETURN && set -e  # exit on err
  echo "Pushing source files to minix image"
  minix_mount_img "$MINIX_WORK_IMAGE_PATH"
  trap 'minix_umount_img; echo_err "Failed to push source files";' ERR

  rm -rf "$MINIX_USR_MOUNT_DIR/src"
  rm -rf "$MINIX_USR_MOUNT_DIR/include"

  cp -rf "$MINIX_SOURCES_DIR/src/." "$MINIX_USR_MOUNT_DIR/src"
  cp -rf "$MINIX_SOURCES_DIR/include/." "$MINIX_USR_MOUNT_DIR/include"

  chown -R 0:0 "$MINIX_USR_MOUNT_DIR/src"
  chown -R 0:0 "$MINIX_USR_MOUNT_DIR/include"

  echo "Successfully pushed source files"
  minix_umount_img
}

prog_pull_sources() {
  trap "$(set +o | grep errexit); trap - ERR" RETURN && set -e  # exit on err
  echo "Pulling source files from minix image"
  minix_mount_img "$MINIX_WORK_IMAGE_PATH"
  trap 'minix_umount_img; echo_err "Failed to pull source files";' ERR

  toolbox_copy_source_dirs_from_mounted_image

  echo "Successfully pulled source files"
  minix_umount_img
}

# CLI utilities

validate_no_options_or_exit() {
  # $1 - command name
  local command=$1
  shift
  if [ $# -gt 0 ]; then
    echo_err "Unknown args '$*' for command '$command'"
    exit 1
  fi
}

# CLI commands


cli_setup() {
  local rebuild=0
  if [ "$1" == "--rebuild" ]; then
    rebuild=1
    shift
  fi
  validate_no_options_or_exit 'setup' "$@"
  prog_img_setup "$rebuild"
}


cli_build() {
  validate_no_options_or_exit 'build' "$@"
  prog_build
}

cli_run() {
  local display=0
  if [ "$1" == "--display" ]; then
    display=1
    shift
  fi
  local filepath="$1"
  shift
  validate_no_options_or_exit 'run' "$@"
  prog_run "$filepath" "$display"
}

cli_push() {
  validate_no_options_or_exit 'push' "$@"
  prog_push_sources
}

cli_pull() {
  validate_no_options_or_exit 'pull' "$@"
  prog_pull_sources
}

# help messages printing

print_usage() {
  cat <<EOF
Minix Toolbox $SCRIPT_VERSION
Usage: $SCRIPT_NAME <command> [command options]

Commands:
  setup [--rebuild]           Download the image from URL (defined in config) and prepare it to be used with this toolbox automation.
                              This command recompiles the downloaded image with RS232 serial port support enabled.
                              A workdir will be initialized by creating toolkit subfolders and copying minix source code from
                              the built image to the 'minix_source' subdirectory.
                              If the current path already contains these subdirs, they will be deleted.
                              Use the optional '--rebuild' flag to only rebuild the minix base image and skip workdir initialization.

  build                       Execute push and run minix compilation (make hdboot) on the current image.

  run [--display] FILEPATH    Run a C/shell script on minix. If it is a C script it will be compiled before execution.
                              Script is treated as C script only if it has a '.c' extension, otherwise it is treated as shell script.
                              Use optional '--display' flag to show text display for minix emulation, this can be useful for displaying
                              printf messages from the kernel.

  push                        Copy changed source files form the workspace to minix image.

  pull                        Copy original source files form minix image to the workspace.

EOF
}

# entrypoint

if [ $# -lt 1 ]; then
  print_usage
  exit 0
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
build)
  cli_build "$@"
  ;;
run)
  cli_run "$@"
  ;;
setup)
  cli_setup "$@"
  ;;
push)
  cli_push "$@"
  ;;
pull)
  cli_pull "$@"
  ;;
# TEMPORARY:
mount)
  minix_mount_img "$MINIX_WORK_IMAGE_PATH"
  ;;
umount)
  minix_umount_img
  ;;
help | --help | -h)
  print_usage
  exit 0
  ;;
*)
  echo_err "Invalid command '$SUBCOMMAND'."
  print_usage >&2
  exit 1
  ;;
esac
