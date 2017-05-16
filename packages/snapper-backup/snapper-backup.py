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
import shutil
import argparse
import subprocess
from datetime import datetime, timedelta

parser = argparse.ArgumentParser(
    description="Uses send/receive to backup Btrfs snapshots")
parser.add_argument("src", help="Source location")
parser.add_argument("dst", help="Destination location")
parser.add_argument("--keep-daily", help="Number of daily snapshots to keep", type=int, default=0)
parser.add_argument("--keep-weekly", help="Number of weekly snapshots to keep", type=int, default=4)
parser.add_argument("--keep-monthly", help="Number of monthly snapshots to keep", type=int, default=12)
parser.add_argument("--dry-run", help="Do not do anything", action="store_true")
args = parser.parse_args()


def btrfs_subvolume_delete(path):
    """Delete a btrfs subvolume"""
    print("Deleting subvolume at %s" % path)
    if args.dry_run:
        return
    return subprocess.check_call(
        ["btrfs", "subvolume", "delete", "--commit-after", path])


def snap_date(path):
    """Return the date at which a snapshot has been taken from its info.xml"""

    try:
        import xml.etree.ElementTree as ET
        root = ET.parse(os.path.join(path, "info.xml"))
        date = root.find("./date").text
        return datetime.strptime(date, "%Y-%m-%d %H:%M:%S")
    except:
        return None


def snap_cleanup(path):
    """Try to cleanup a snapper snapshot"""
    print("Cleaning up snapshot at %s" % path)
    if args.dry_run:
        return
    try:
        os.unlink(os.path.join(path, "info.xml"))
    except:
        print("Cannot unlink %s" % os.path.join(path, "info.xml"))
    try:
        btrfs_subvolume_delete(os.path.join(path, "snapshot"))
    except:
        print("Cannot delete %s" % os.path.join(path, "snapshot"))
    try:
        os.rmdir(path)
    except:
        print("Cannot delete base directory %s" % path)


def snap_send_receive(common, src_path, dst_path):
    """Send a snapshot from source to destination

    :param list common: list of source subvolumes that also exist in the destination
    :param str src_path: source snapper snapshot directory
    :param str dst_path: destination snapper snapshot directory
    """

    print("Sending snapshot %s to %s..." % (name, args.dst))
    if args.dry_run:
        return

    # Send a snapper snapshot (e.g. 241/snapshot) to the destination directory
    # (241/). The snapshot will appear as a subvolume with the same name as the
    # source.

    # Build the command-line
    src_subvolume_path = os.path.join(src_path, "snapshot")
    cmd_send = ["ionice", "-c", "3", "btrfs", "send", "-v", src_subvolume_path]
    for subvolume_path in common:
        cmd_send += ["-c", subvolume_path]
    cmd_recv = ["ionice", "-c", "3", "btrfs", "receive", "-v", dst_path]
    print("Send: %s" % subprocess.list2cmdline(cmd_send))
    print("Recv: %s" % subprocess.list2cmdline(cmd_recv))

    # Open with processes and wait for completion
    proc_send = subprocess.Popen(cmd_send, stdout=subprocess.PIPE)
    proc_recv = subprocess.Popen(cmd_recv, stdin=proc_send.stdout)
    while proc_recv.returncode is None and proc_send.returncode is None:
        try:
            proc_recv.wait(1) and proc_send.wait(1)
        except subprocess.TimeoutExpired:
            pass
    if proc_send.wait() > 0:
        raise Exception("The `btrfs send` process exited with code %d" % ret_send)
    if proc_recv.wait() > 0:
        raise Exception("The `btrfs receive` process exited with code %d" % ret_recv)

    # Copy snapshot metadata
    shutil.copy(os.path.join(src_path, "info.xml"), os.path.join(dst_path, "info.xml"))

# Determine what we have to transfer, as well as what we need to cleanup
src_names = os.listdir(args.src)
src_snapshots = [os.path.join(args.src, name) for name in src_names]
dst_names = os.listdir(args.dst)
dst_snapshots = [os.path.join(args.dst, name) for name in dst_names]
dates = {}
dates.update({name: snap_date(os.path.join(args.src, name)) for name in src_names})
dates.update({name: snap_date(os.path.join(args.dst, name)) for name in dst_names})
dates = {name: date for name, date in dates.items() if date}
to_keep_daily = []
to_keep_weekly = []
to_keep_monthly = []
last_daily_interval = last_weekly_interval = last_monthly_interval = 31
for name, date in sorted(dates.items(), key=lambda q: q[1], reverse=True):
    if not date:
        continue
    if to_keep_daily:
        last_daily_interval = (dates[to_keep_daily[-1]] - date).days
    if to_keep_weekly:
        last_weekly_interval = (dates[to_keep_weekly[-1]] - date).days
    if to_keep_monthly:
        last_monthly_interval = (dates[to_keep_monthly[-1]] - date).days
    if last_daily_interval >= 1 and len(to_keep_daily) < args.keep_daily:
        to_keep_daily.append(name)
    if last_weekly_interval >= 7 and len(to_keep_weekly) < args.keep_weekly:
        to_keep_weekly.append(name)
    if last_monthly_interval >= 31 and len(to_keep_monthly) < args.keep_monthly:
        to_keep_monthly.append(name)

# Prepare sets
to_keep = set(to_keep_daily + to_keep_weekly + to_keep_monthly)
common = set(src_names).intersection(dst_names)
missing = set(src_names).difference(dst_names).intersection(to_keep)
obsolete = set(dst_names).difference(to_keep)
if to_keep_daily:
    print("Daily snapshots: %s" % ", ".join(sorted(to_keep_daily)))
if to_keep_weekly:
    print("Weekly snapshots: %s" % ", ".join(sorted(to_keep_weekly)))
if to_keep_monthly:
    print("Monthly snapshots: %s" % ", ".join(sorted(to_keep_monthly)))

if missing:
    print("Missing snapshots: %s" % ", ".join(sorted(missing)))
else:
    print("No missing snapshots to back up.")
for name in sorted(missing, key=lambda n: dates[n]):
    src_path = os.path.join(args.src, name)
    dst_path = os.path.join(args.dst, name)
    if not os.path.exists(src_path):
        continue
    try:
        if not args.dry_run:
            os.mkdir(dst_path)
    except FileExistsError:
        continue
    try:
        snap_send_receive(
            [os.path.join(args.src, path, "snapshot") for path in common],
            src_path, dst_path)
    except:
        snap_cleanup(dst_path)  # Try to clean things up on errors
        raise
    common.add(name)

if obsolete:
    print("Obsolete snapshots: %s" % ", ".join(sorted(obsolete)))
else:
    print("No old snapshots to clean up.")
for name in obsolete:
    snap_cleanup(os.path.join(args.dst, name))
