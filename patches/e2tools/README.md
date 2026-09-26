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
symlink that array holds the target path inline, not block pointers. Deleting a link to
`/lib/systemd/system/serial-getty@.service` frees `i_block[10]` — the trailing `e\0\0\0` of
`.service` — as **block 101**. Out-of-range words print `Illegal block number` and are ignored; an
in-range one is cleared in the block bitmap silently. The next file written gets a block that
metadata still owns, and the kernel remounts the rootfs read-only on first boot.

`debugfs`, which this code derives from, guards the same call with
`ext2fs_inode_has_valid_blocks2()`. The patch restores it, which also covers device nodes, FIFOs,
sockets and inline-data inodes.

Only **fast** symlinks are affected — a target of 60 bytes or more gets a real data block and always
deleted correctly, which is why this looked intermittent.

## 0002

A directory's `i_links_count` starts at 2 — its entry in the parent, and its own `.`. `rm_file()`
decrements once and frees only at zero, so it lands on 1 and the inode is never freed: an orphan, a
stale `..`, a parent link count one too high, a leaked block. The patch also gives back the parent's
link for the child's `..`, and frees the inode with `ext2fs_inode_alloc_stats2()` so the group
descriptor's `used_dirs_count` follows.

## An image from a box that did not shut down cleanly

libext2fs does not replay the ext4 journal, so editing such an image writes over metadata still
waiting in it. `e2fsck` it first, on the host:

```sh
e2fsck -fy <image-or-device>    # Homebrew keeps it in $(brew --prefix e2fsprogs)/sbin
```

## Verifying

`./build-e2tools.sh --test` re-runs the gate. Every case must leave the same block count as an
untouched filesystem: a leak reads high, a double-free as an `fsck` complaint.

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

| What            | Where                                                              |
| --------------- | ------------------------------------------------------------------ |
| `0001` + `0002` | reported as issue #38, submitted as PR #39 (applies to `master`)   |
| `0003`          | superseded by PR #37, which does the same and updates the man page |

`0003` stays because we build `v0.1.2`, which predates #37. Drop it when a release carries that PR,
and `0001`/`0002` when one carries #39.

The project is dormant — last commit 2024-09-15, PRs open since 2020 — so assume these stay local.
