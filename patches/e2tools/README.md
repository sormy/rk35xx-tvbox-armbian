# e2tools — patches

Stock e2tools cannot safely edit an ext4 image. `../../build-e2tools.sh` fetches e2tools `v0.1.2`,
applies these, builds to `tools/e2tools/`, and gates the result. `build-image.sh` puts that
directory ahead of `PATH` and refuses to run without it.

| Patch  | Fixes                                                        |
| ------ | ------------------------------------------------------------ |
| `0001` | `e2rm` on a symlink frees the target string as block numbers |
| `0002` | `e2rm -r` unlinks a directory without freeing it             |
| `0003` | `e2ln -s`, which upstream answers with "Not implemented yet" |

## 0001 — the one that bricked two images

`delete_file()` hands every word of `i_block[]` to `ext2fs_block_alloc_stats(..., -1)`. For a fast
symlink that array is not block pointers: it holds the target path inline. Deleting a link to
`/lib/systemd/system/serial-getty@.service` frees `i_block[10]` — the trailing `e\0\0\0` of
`.service` — as **block 101**. Out-of-range words print `Illegal block number` and are ignored; an
in-range one is cleared in the block bitmap with no message at all. The next file written to the
image is handed a block that metadata still owns, and the kernel remounts the rootfs read-only on
first boot.

`debugfs`, which this code is derived from, guards the same call with
`ext2fs_inode_has_valid_blocks2()`. The patch restores it. That also covers device nodes, FIFOs,
sockets and inline-data inodes.

Only **fast** symlinks are affected — a target of 60 bytes or more gets a real data block and was
always deleted correctly, which is why this looked intermittent.

## 0002

A directory's `i_links_count` starts at 2 — its entry in the parent, and its own `.`. `rm_file()`
decrements once and frees only at zero, so it lands on 1 and the inode is never freed: an orphan, a
stale `..`, a parent link count one too high, and a leaked block. The parent's link for the child's
`..` is given back here too, and the inode is freed with `ext2fs_inode_alloc_stats2()` so the group
descriptor's `used_dirs_count` follows.

## Verifying

`./build-e2tools.sh --test` re-runs the gate. Every case must leave the filesystem on the same block
count as an untouched one — a leak reads as a higher count, a double-free as an `fsck` complaint.

```
PASS  rm regular file        2357/16384 blocks
PASS  rm fast symlink        2357/16384 blocks
PASS  rm slow symlink        2357/16384 blocks
PASS  rm -r directory        2357/16384 blocks
PASS  rm -r nested           2357/16384 blocks
PASS  e2ln -s                target reads back
```

Upstream's own suite is a single test that never deletes anything, which is how both bugs survived.

## Upstream

Neither fix is upstream (checked against `master`, 2026-08); the tarball and `master` carry the same
unguarded call. Each patch here is formatted to send.
