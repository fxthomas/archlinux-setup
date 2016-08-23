#!/usr/bin/python
# coding=utf-8

# Base Python File (snapper-backup.py)
# Created: Fri 19 Aug 2016 09:18:51 PM CEST
# Version: 1.0
#
# This Python script was developped by François-Xavier Thomas.
# You are free to copy, adapt or modify it.
#
# (ɔ) François-Xavier Thomas <fx.thomas@gmail.com>

import os
import argparse
import subprocess

parser = argparse.ArgumentParser(
    description="Uses send/receive to backup Btrfs snapshots")
parser.add_argument("src", help="Source location")
parser.add_argument("dst", help="Destination location")
args = parser.parse_args()

# Cleanup temporary snapshots
tmp_path = os.path.join(args.dst, "snapshot")
if os.path.exists(tmp_path):
    print("Temporary snapshot %s still exists, removing...")
    subprocess.check_call(
        ["btrfs", "subvolume", "delete", "--commit-after", tmp_path])

# List source and destination snapshots
src_snapshots = os.listdir(args.src)
dst_snapshots = os.listdir(args.dst)

# Find out already backed-up and missing snapshots
common = set(src_snapshots).intersection(dst_snapshots)
missing = set(src_snapshots).difference(dst_snapshots)

# Backup each missing snapshot
for name in missing:

    src_path = os.path.join(args.src, name, "snapshot")
    dst_path = os.path.join(args.dst, name)

    if not os.path.exists(src_path):
        continue

    print("Sending snapshot %s to %s..." % (name, args.dst))

    cmd_send = ["btrfs", "send", src_path]
    for path in common:
        cmd_send += ["-c", os.path.join(args.src, path, "snapshot")]
    cmd_recv = ["btrfs", "receive", args.dst]

    try:
        proc_send = subprocess.Popen(cmd_send, stdout=subprocess.PIPE)
        proc_recv = subprocess.Popen(cmd_recv, stdin=proc_send.stdout)
        ret_send = proc_send.wait()
        ret_recv = proc_recv.wait()
        if ret_send > 0:
            raise Exception("The `btrfs send` process exited with code %d" % ret_send)
        if ret_recv > 0:
            raise Exception("The `btrfs receive` process exited with code %d" % ret_recv)
    except:
        subprocess.check_call(["btrfs", "subvolume", "delete", tmp_path])
        raise
    else:
        os.rename(tmp_path, dst_path)
