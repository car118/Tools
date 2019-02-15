#!/bin/bash

# This is the kind of script I use to conveniently mount and unmount an EncFS
# encrypted filesystem on a USB stick or a similar portable drive.
#
# WARNING: This script contains a password in clear text, so always keep it
#          inside an encrypted filesystem. Do not copy this script to an unencrypted drive
#          with the clear-text password inside!
#
# The first time you will have to create your encrypted filesystem manually.
# Mount your USB stick and run a command like this:
#
#     encfs "/media/$USER/YourVolumeId/YourEncryptedDir" "$HOME/AllYourMountDirectories/YourMountDirectory"
#
# Unmount it with:
#
#     fusermount --unmount "$HOME/AllYourMountDirectories/YourMountDirectory"
#
# The edit variables USB_DATA_PATH etc. below in this script.
#
# Afterwards, use this script to mount and dismount it with a minimum of fuss:
#
#   mount-encrypted-filesystem.sh
#
#   mount-encrypted-filesystem.sh umount
#
#
# Copyright (c) 2018-2019 R. Diez - Licensed under the GNU AGPLv3

set -o errexit
set -o nounset
set -o pipefail

# This is where you system normally automounts the USB stick.
declare -r USB_DATA_PATH="/media/$USER/YourVolumeId/YourEncryptedDir"

declare -r ENC_FS_PASSWORD="YourComplexPassword"

# This is where you want to mount the encrypted filesystem.
declare -r ENC_FS_MOUNTPOINT="$HOME/AllYourMountDirectories/YourMountDirectory"

declare -r ENCFS_TOOL="encfs"

declare -r EXIT_CODE_ERROR=1
declare -r BOOLEAN_TRUE=0
declare -r BOOLEAN_FALSE=1


abort ()
{
  echo >&2 && echo "Error in script \"$0\": $*" >&2
  exit "$EXIT_CODE_ERROR"
}


is_dir_empty ()
{
  shopt -s nullglob
  shopt -s dotglob  # Include hidden files.

  # Command 'local' is in a separate line, in order to prevent masking any error from the external command (or operation) invoked.
  local -a FILES
  FILES=( "$1"/* )

  if [ ${#FILES[@]} -eq 0 ]; then
    return $BOOLEAN_TRUE
  else
    if false; then
      echo "Files found: ${FILES[*]}"
    fi
    return $BOOLEAN_FALSE
  fi
}


mount_usb_stick ()
{
  if ! test -d "$USB_DATA_PATH"; then
    abort "Directory \"$USB_DATA_PATH\" does not exist."
  fi

  mkdir --parents -- "$ENC_FS_MOUNTPOINT"

  if ! is_dir_empty "$ENC_FS_MOUNTPOINT"; then
    abort "Mount point \"$ENC_FS_MOUNTPOINT\" is not empty (already mounted?). While not strictly a requirement for mounting purposes, this script does not expect a non-empty mountpoint."
  fi

  local CMD_MOUNT
  printf -v CMD_MOUNT "%q --stdinpass  -- %q  %q"  "$ENCFS_TOOL"  "$USB_DATA_PATH"  "$ENC_FS_MOUNTPOINT"

  echo "$CMD_MOUNT"
  eval "$CMD_MOUNT" <<<"$ENC_FS_PASSWORD"


  local CMD_OPEN_FOLDER

  # Opening a folder is more comfortable with my StartDetached.sh script and with KDE's Dolphin.
  #   printf -v CMD_OPEN_FOLDER  "StartDetached.sh -- dolphin --select %q"  "$ENC_FS_MOUNTPOINT"

  printf -v CMD_OPEN_FOLDER  "xdg-open %q"  "$ENC_FS_MOUNTPOINT"

  echo "$CMD_OPEN_FOLDER"
  eval "$CMD_OPEN_FOLDER"
}


unmount_usb_stick ()
{
  local CMD_UNMOUNT
  printf -v CMD_UNMOUNT "fusermount -u -z -- %q"  "$ENC_FS_MOUNTPOINT"

  echo "$CMD_UNMOUNT"
  eval "$CMD_UNMOUNT"
}


# ------- Entry point -------

ERR_MSG="Only one optional argument is allowed: 'mount' (the default), or 'unmount' / 'umount'."

if (( $# == 0 )); then

  MODE=mount

elif (( $# == 1 )); then

  case "$1" in
    mount)    MODE=mount;;
    unmount)  MODE=unmount;;
    umount)   MODE=unmount;;
    *) abort "Wrong argument \"$1\". $ERR_MSG";;
  esac

else
  abort "Invalid arguments. $ERR_MSG"
fi


case "$MODE" in
  mount)   mount_usb_stick;;
  unmount) unmount_usb_stick;;

  *) abort "Internal error: Invalid mode \"$MODE\".";;
esac