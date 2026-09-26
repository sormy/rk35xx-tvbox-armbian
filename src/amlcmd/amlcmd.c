/* Talk to an Amlogic box in USB burning mode. See README.md for the protocol. */
#include <errno.h>
#include <libusb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define IDENTIFY 0x20

/* The mask ROM answers the same vendor requests as the burning gadget, with a
   different handler set: memory and code, and no notion of storage. */
#define WRITE_MEM 0x01
#define READ_MEM 0x02
#define RUN_IN_ADDR 0x05
#define KEEP_POWER 0x10
#define MEM_CHUNK 64         /* the ROM takes memory a control transfer at a time */
#define TPL_CMD 0x30
#define TPL_STAT 0x31
#define DOWNLOAD 0x32
#define UPLOAD 0x33

#define EP_IN 0x81
#define EP_OUT 0x02
#define MPS 512              /* a bulk IN must be asked for in whole packets */
#define BLK (8 * MPS)        /* DWC_BLK_MAX_LEN: what the gadget arms per block */
#define ACK_LEN 512          /* AM_BULK_REPLY_LEN */
#define CMD_LEN 64
#define REPLY_LEN 128        /* "success"/"failed:" plus whatever the handler appended */
#define SLOT (64 * 1024)     /* OPTIMUS_DOWNLOAD_SLOT_SZ */
#define XFER_MAGIC 0xefe8
#define CKC_ADDSUM 0xef

#define SECTOR 512
#define MMC_PORTS 3          /* SDIO ports A, B and C */

#define FAST_MS 5000
#define SLOW_MS 60000
#define BULK_MS 15000

static libusb_device_handle *dev;
static uint8_t ident[8];     /* ROM major.minor then stage major.minor */
static char stage[16];       /* the staging address as the string the parser wants */

/* What differs between boxes. The defaults are what one GX-family box measured;
   another family sets its own here rather than in a rebuild. Everything above is
   the protocol, which every family shares. */
static struct {
    uint16_t vid, pid;
    unsigned mmc_dev;        /* `amlmmc list` on the box: which port carries the eMMC */
    uint32_t stage_addr;     /* DRAM clear of U-Boot and of the gadget's own buffers */
    uint64_t window;         /* sectors staged per backup or restore round trip */
    int mode;                /* 1 mask ROM, 0 burning gadget, -1 let identify decide */
} cfg;

/* The environment is read before the device is opened, so a typo costs nothing. */
static _Noreturn void bad_cfg(const char *what) {
    fprintf(stderr, "%s\n", what);
    exit(2);
}

static unsigned long env_num(const char *name, unsigned long def) {
    const char *s = getenv(name);
    return s && *s ? strtoul(s, NULL, 0) : def;
}

static int env_mode(void) {
    const char *mode = getenv("AML_MODE");
    if (!mode) return -1;
    if (!strcmp(mode, "rom")) return 1;
    if (!strcmp(mode, "gadget")) return 0;
    bad_cfg("AML_MODE must be rom or gadget");
}

static void load_cfg(void) {
    cfg.vid = (uint16_t)env_num("AML_VID", 0x1b8e);
    cfg.pid = (uint16_t)env_num("AML_PID", 0xc003);
    cfg.mmc_dev = (unsigned)env_num("AML_MMC_DEV", 1);
    cfg.stage_addr = (uint32_t)env_num("AML_STAGE_ADDR", 0x20000000);
    cfg.window = env_num("AML_WINDOW_MIB", 32) * 1024 * 1024 / SECTOR;
    cfg.mode = env_mode();
    if (!cfg.window) bad_cfg("AML_WINDOW_MIB must be at least 1");
    snprintf(stage, sizeof stage, "0x%x", cfg.stage_addr);
}

static void cleanup(void) {
    if (!dev) return;
    libusb_release_interface(dev, 0);
    libusb_close(dev);
    dev = NULL;
    libusb_exit(NULL);
}

/* A failed transfer leaves its chunk queued, and it would head the next one. The
   read that ends the loop always times out, and a timed-out read leaves the pipe
   halted, so clear it on the way out or draining breaks what it was fixing. */
static int drain_in(void) {
    static uint8_t junk[SLOT];
    int n = 0, total = 0;
    libusb_clear_halt(dev, EP_IN);
    while (libusb_bulk_transfer(dev, EP_IN, junk, SLOT, &n, 500) == 0 && n) total += n;
    libusb_clear_halt(dev, EP_IN);
    return total;
}

/* A host-side failure: there is nothing on the box to recover from. */
static void fail(const char *what) {
    fprintf(stderr, "%s: %s\n", what, strerror(errno));
    exit(1);
}

static void die(const char *what, int rc) {
    fprintf(stderr, "%s: %s\n", what, rc ? libusb_strerror(rc) : "failed");
    if (dev) {
        int left = drain_in();
        if (left) fprintf(stderr, "recovered: flushed %d stranded bytes\n", left);
    }
    exit(1);
}

/* DWC_BLK_LEN: the gadget re-arms a block at a time, and a longer write overruns it. */
static int blk_len(size_t left) {
    if (left >= BLK) return BLK;
    return left >= MPS ? (int)(left / MPS) * MPS : (int)left;
}

/* The gadget's own checksum over a download chunk: 32-bit words, wrapping. */
static uint32_t add_sum(const uint8_t *p, size_t n) {
    uint32_t sum = 0, tail = 0;
    size_t i = 0;
    for (; i + 4 <= n; i += 4)
        sum += (uint32_t)p[i] | p[i + 1] << 8 | p[i + 2] << 16 | p[i + 3] << 24;
    for (size_t s = 0; i < n; i++, s += 8) tail |= (uint32_t)p[i] << s;
    return sum + tail;
}

static const char USAGE[] =
    "amlcmd's own verbs:\n"
    "  connect                     wait for the box and arm the link\n"
    "  status                      which gadget is answering\n"
    "  probe                       find the eMMC device and prove the staging address\n"
    "  drain                       flush a chunk a killed transfer stranded\n"
    "  read {mem|store} <addr|part> <size> <out>\n"
    "  write {mem|store} <addr|part> <in>\n"
    "  backup <out> [start] [count]   raw eMMC sectors, whole device by default\n"
    "  restore <in> [start]           raw eMMC sectors\n"
    "  rom {read <addr> <size> <out>|write <addr> <in>|run <addr>}\n"
    "                              the mask ROM: memory and code, no storage\n"
    "\n"
    "anything else is passed to the box as a command, U-Boot's or the gadget's:\n"
    "  amlcmd printenv upgrade_step\n"
    "  amlcmd amlmmc part 1\n"
    "  amlcmd set_usb_boot 2\n"
    "  amlcmd reset\n"
    "\n"
    "what a different box changes, `probe` reports, and the environment sets:\n"
    "  AML_MMC_DEV=<discovered>  AML_STAGE_ADDR=0x20000000  AML_WINDOW_MIB=32\n"
    "  AML_VID=0x1b8e  AML_PID=0xc003  AML_MODE=<rom|gadget, else identify decides>\n";

/* A subcommand typed with the wrong arity must not fall through to the gadget as a
   U-Boot command; say what was expected instead. */
static int misuse(const char *line) {
    fprintf(stderr, "usage: %s\n", line);
    return 2;
}

/* An explicit product id is taken at face value; without one, any device the vendor
   answers for will do, which is what reaches a family that numbers its gadget
   differently. The exact pair is tried first, so the proven path is unchanged. */
static libusb_device_handle *open_box(void) {
    libusb_device_handle *h = libusb_open_device_with_vid_pid(NULL, cfg.vid, cfg.pid);
    libusb_device **list = NULL;
    if (h || getenv("AML_PID")) return h;
    ssize_t n = libusb_get_device_list(NULL, &list);
    for (ssize_t i = 0; i < n && !h; i++) {
        struct libusb_device_descriptor desc;
        if (libusb_get_device_descriptor(list[i], &desc) || desc.idVendor != cfg.vid) continue;
        if (libusb_open(list[i], &h) == 0) cfg.pid = desc.idProduct;
    }
    if (n >= 0) libusb_free_device_list(list, 1);
    return h;
}

static int connect_box(int wait_s) {
    for (int t = 0; t <= wait_s * 20; t++) {
        dev = open_box();
        if (dev) {
            for (int i = 0; i < 40; i++)
                if (libusb_control_transfer(dev, 0xc0, IDENTIFY, 0, 0, ident, 8, 2000) == 8) {
                    /* On Linux a kernel driver may hold the interface; harmlessly
                       unsupported elsewhere. */
                    libusb_set_auto_detach_kernel_driver(dev, 1);
                    /* Claim before any bulk transfer: claiming with one already
                       armed fails the first read and strands the chunk. */
                    int rc = libusb_claim_interface(dev, 0);
                    if (rc < 0) die("claim interface", rc);
                    return 0;
                }
            libusb_close(dev);
            dev = NULL;
        }
        usleep(50000);
    }
    return -1;
}

/* "success"/"failed:" at [0:7], the handler's detail at [7:]. reply may be NULL
   for a command whose verdict is deliberately ignored. */
static int command(const char *cmd, char *reply) {
    uint8_t buf[CMD_LEN] = {0};
    static const char *slow_cmds[] = {"amlmmc",   "store",  "upload", "download",
                                      "disk_initial", "usb",    "ext4load", "fatload",
                                      "booti",    "autoscr", "run"};
    int slow = 0;
    for (size_t i = 0; i < sizeof slow_cmds / sizeof *slow_cmds; i++)
        slow |= !strncmp(cmd, slow_cmds[i], strlen(slow_cmds[i]));
    unsigned timeout = slow ? SLOW_MS : FAST_MS;
    if (strlen(cmd) >= CMD_LEN) return -1;
    memcpy(buf, cmd, strlen(cmd));
    /* wIndex 1 is the subcode the gadget runs on; with 0 it silently does nothing. */
    int rc = libusb_control_transfer(dev, 0x40, TPL_CMD, 0, 1, buf, CMD_LEN, timeout);
    if (rc < 0) goto failed;
    usleep(300000);
    for (unsigned waited = 0; waited < timeout; waited += 50) {
        uint8_t st[CMD_LEN] = {0};
        rc = libusb_control_transfer(dev, 0xc0, TPL_STAT, 0, 0, st, CMD_LEN, FAST_MS);
        if (rc < 0) goto failed;
        if (st[0]) {
            const char *head = (const char *)st, *detail = head + 7;
            int ok = !strncmp(head, "success", 7);
            if (reply) {
                if (*detail)
                    snprintf(reply, REPLY_LEN, "%.7s %.56s", head, detail);
                else if (ok)
                    snprintf(reply, REPLY_LEN, "%.7s", head);
                else
                    /* Some handlers never write the reply buffer at all and printf
                       their reason, so it leaves by the UART and not by USB. */
                    snprintf(reply, REPLY_LEN, "%.7s no detail over USB, watch the "
                                               "serial console for the reason", head);
            }
            return ok ? 0 : 1;
        }
        usleep(50000);
    }
    if (reply) strcpy(reply, "<no reply>");
    return 1;
failed:
    if (reply) snprintf(reply, REPLY_LEN, "<%s>", libusb_strerror(rc));
    return rc;
}

static void run(const char *cmd) {
    char reply[REPLY_LEN];
    if (command(cmd, reply) != 0) {
        fprintf(stderr, "%s -> %s\n", cmd, reply);
        exit(1);
    }
}

/* libusb will not ask the endpoint for a partial packet: round the request up to a
   whole one and keep what the gadget actually sent. */
static int read_bulk(uint8_t *out, int want) {
    static uint8_t tail[MPS];
    int aligned = want / MPS * MPS, got = 0, n, rc;
    while (got < aligned) {
        rc = libusb_bulk_transfer(dev, EP_IN, out + got, aligned - got, &n, BULK_MS);
        if (rc < 0) return rc;
        got += n;
    }
    if (got < want) {                       /* a tail shorter than one packet */
        rc = libusb_bulk_transfer(dev, EP_IN, tail, MPS, &n, BULK_MS);
        if (rc < 0) return rc;
        if (n > want - got) n = want - got;
        memcpy(out + got, tail, n);
        got += n;
    }
    return got;
}

/* The 16-byte AM_REQ_UPLOAD control IN is itself what arms the bulk IN: the gadget
   starts it from do_vendor_in_complete once that read completes. */
static void upload(const char *media, const char *name, size_t size, FILE *out) {
    char cmd[CMD_LEN];
    static uint8_t chunk[SLOT];
    if (!strcmp(media, "store")) command("disk_initial 0", NULL);
    snprintf(cmd, sizeof cmd, "upload %s %s normal 0x%zx", media, name, size);
    run(cmd);
    for (size_t done = 0; done < size;) {
        uint8_t head[16];
        if (libusb_control_transfer(dev, 0xc0, UPLOAD, 0, 0, head, 16, FAST_MS) < 0)
            die("upload header", 0);
        uint32_t magic = head[0] | head[1] << 8 | head[2] << 16 | head[3] << 24;
        uint32_t want = head[4] | head[5] << 8 | head[6] << 16 | head[7] << 24;
        if (magic != XFER_MAGIC) die("bad upload header", 0);
        if (!want) break;
        int got = read_bulk(chunk, want);
        if (got < 0) die("bulk read", got);
        if (fwrite(chunk, 1, got, out) != (size_t)got) fail("write");
        done += got;
    }
}

/* Mirror of upload: a 32-byte control OUT per chunk, the data on the bulk OUT, then
   the gadget's verdict on the bulk IN. */
static void download(const char *media, const char *name, const uint8_t *data, size_t len) {
    char cmd[CMD_LEN];
    if (!strcmp(media, "store")) command("disk_initial 0", NULL);
    snprintf(cmd, sizeof cmd, "download %s %s normal 0x%zx", media, name, len);
    run(cmd);
    for (size_t off = 0, seq = 1; off < len; off += SLOT, seq++) {
        uint32_t n = (uint32_t)(len - off < SLOT ? len - off : SLOT);
        uint32_t head[8] = {0, n, (uint32_t)seq, add_sum(data + off, n),
                            (ACK_LEN << 16) | CKC_ADDSUM, 0, 0, 0};
        /* wIndex 65535 with a 32-byte stage selects the framing that carries a
           checksum and an ack length; wValue is recomputed by the gadget. */
        if (libusb_control_transfer(dev, 0x40, DOWNLOAD, 0, 65535, (uint8_t *)head,
                                    sizeof head, FAST_MS) < 0)
            die("download header", 0);
        for (uint32_t sent = 0; sent < n;) {
            int step = blk_len(n - sent), moved = 0;
            int rc = libusb_bulk_transfer(dev, EP_OUT, (uint8_t *)data + off + sent, step,
                                          &moved, BULK_MS);
            if (rc < 0) die("bulk write", rc);
            sent += moved;
        }
        uint8_t ack[ACK_LEN];
        if (read_bulk(ack, ACK_LEN) < 0 || memcmp(ack, "OK!!", 4)) die("chunk rejected", 0);
    }
}

/* The key window inside `reserved` refuses to be read until the guard is lifted, and
   it sits in the middle of the device, not at an end. A box with no such window has no
   such command either, and a pass that never crosses one works without it. */
static void disprotect_key(void) {
    char reply[REPLY_LEN];
    if (command("store disprotect key", reply) != 0)
        fprintf(stderr, "key guard not lifted (%s); a range crossing it will fail\n", reply);
}

/* 0 when the box will not say, which only a caller that needs the number minds. */
static uint64_t emmc_sectors(void) {
    static uint64_t cached;
    char cmd[CMD_LEN];
    uint64_t n = 0;
    if (cached) return cached;
    snprintf(cmd, sizeof cmd, "amlmmc size wholeDev 0x%x", cfg.stage_addr);
    if (command(cmd, NULL) != 0) return 0;
    FILE *tmp = tmpfile();
    upload("mem", stage, 8, tmp);
    rewind(tmp);
    if (fread(&n, 1, 8, tmp) != 8) die("size readback", 0);
    fclose(tmp);
    return cached = n;
}

/* `amlmmc list` names the ports, but its output never leaves the UART. What does
   cross is a verdict, so the device is the one that can read the last sector of the
   size `amlmmc size wholeDev` reports: anything smaller, or absent, fails on it. */
static int discover_mmc_dev(void) {
    char cmd[CMD_LEN];
    uint64_t sectors = emmc_sectors();
    int found = -1;
    if (!sectors) return -1;
    for (unsigned d = 0; d < MMC_PORTS; d++) {
        snprintf(cmd, sizeof cmd, "amlmmc read %u 0x%x 0x%llx 1", d, cfg.stage_addr,
                 (unsigned long long)(sectors - 1));
        if (command(cmd, NULL) != 0) continue;
        if (found >= 0) return -1;      /* two of the same size: nothing here separates them */
        found = (int)d;
    }
    return found;
}

/* An explicit device is never second-guessed, and a write never proceeds on a guess. */
static void resolve_mmc_dev(int writing) {
    if (getenv("AML_MMC_DEV")) return;
    int found = discover_mmc_dev();
    if (found >= 0) {
        cfg.mmc_dev = (unsigned)found;
        fprintf(stderr, "eMMC: dev %u\n", cfg.mmc_dev);
    } else if (writing) {
        die("cannot tell which device holds the eMMC - set AML_MMC_DEV", 0);
    } else {
        fprintf(stderr, "eMMC not identified, falling back to dev %u\n", cfg.mmc_dev);
    }
}

/* The staging address has to be DRAM that nothing else is using. A transfer writes
   there anyway, so proving it first costs one round trip and fails while it is
   still cheap - a box whose DRAM ends below it stops here, not mid-image. */
static int stage_reads_back(void) {
    uint8_t out[MEM_CHUNK], back[MEM_CHUNK] = {0};
    for (size_t i = 0; i < sizeof out; i++) out[i] = (uint8_t)(i * 7 + 1);
    download("mem", stage, out, sizeof out);
    FILE *tmp = tmpfile();
    if (!tmp) fail("tmpfile");
    upload("mem", stage, sizeof back, tmp);
    rewind(tmp);
    int ok = fread(back, 1, sizeof back, tmp) == sizeof back && !memcmp(out, back, sizeof out);
    fclose(tmp);
    return ok;
}

/* Both gadgets enumerate alike, so identify is the only thing that separates them.
   The ROM version is family-specific - 2.4 here, where the burning gadget answers 0.7
   - but a stage of 0.0 means nothing is staged behind the ROM on any of them. */
static int is_mask_rom(void) {
    return cfg.mode < 0 ? !ident[2] && !ident[3] : cfg.mode;
}

static void rom_read(uint32_t addr, size_t size, FILE *out) {
    uint8_t buf[MEM_CHUNK];
    for (size_t off = 0; off < size; off += MEM_CHUNK) {
        int n = size - off < MEM_CHUNK ? (int)(size - off) : MEM_CHUNK;
        uint32_t a = addr + (uint32_t)off;
        if (libusb_control_transfer(dev, 0xc0, READ_MEM, a >> 16, a & 0xffff, buf, n,
                                    FAST_MS) != n)
            die("rom read", 0);
        fwrite(buf, 1, n, out);
    }
}

static void rom_write(uint32_t addr, const uint8_t *data, size_t len) {
    for (size_t off = 0; off < len; off += MEM_CHUNK) {
        int n = len - off < MEM_CHUNK ? (int)(len - off) : MEM_CHUNK;
        uint32_t a = addr + (uint32_t)off;
        if (libusb_control_transfer(dev, 0x40, WRITE_MEM, a >> 16, a & 0xffff,
                                    (uint8_t *)data + off, n, FAST_MS) != n)
            die("rom write", 0);
    }
}

static void progress(uint64_t done, uint64_t total) {
    fprintf(stderr, "\r  %.1f/%.1f MiB", done / 1048576.0, total / 1048576.0);
}

/* Read a whole file; the caller frees. */
static uint8_t *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) fail(path);
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    uint8_t *buf = malloc(n ? (size_t)n : 1);
    if (!buf) fail("malloc");
    if (fread(buf, 1, n, f) != (size_t)n) fail(path);
    fclose(f);
    *len = (size_t)n;
    return buf;
}

static void cmd_read(char **argv) {
    FILE *out = fopen(argv[5], "wb");
    if (!out) fail(argv[5]);
    upload(argv[2], argv[3], strtoull(argv[4], NULL, 0), out);
    if (fclose(out)) fail(argv[5]);
}

static void cmd_write(char **argv) {
    size_t len;
    uint8_t *buf = slurp(argv[4], &len);
    download(argv[2], argv[3], buf, len);
    free(buf);
}

static void cmd_backup(int argc, char **argv) {
    char cmd[CMD_LEN];
    disprotect_key();
    resolve_mmc_dev(0);
    uint64_t start = argc > 3 ? strtoull(argv[3], NULL, 0) : 0;
    uint64_t count = argc > 4 ? strtoull(argv[4], NULL, 0) : 0;
    if (!count) {
        uint64_t sectors = emmc_sectors();
        if (!sectors) die("the box will not give its size - pass a count", 0);
        count = sectors - start;
    }
    FILE *out = fopen(argv[2], "wb");
    if (!out) fail(argv[2]);
    for (uint64_t off = 0; off < count; off += cfg.window) {
        uint64_t n = count - off < cfg.window ? count - off : cfg.window;
        snprintf(cmd, sizeof cmd, "amlmmc read %u 0x%x 0x%llx 0x%llx", cfg.mmc_dev,
                 cfg.stage_addr, (unsigned long long)(start + off),
                 (unsigned long long)n);
        run(cmd);
        upload("mem", stage, n * SECTOR, out);
        progress((off + n) * SECTOR, count * SECTOR);
    }
    if (fclose(out)) fail(argv[2]);
    fprintf(stderr, "\nread %llu sectors into %s\n", (unsigned long long)count, argv[2]);
}

static void cmd_restore(int argc, char **argv) {
    char cmd[CMD_LEN];
    disprotect_key();              /* the image holds this box's own key window */
    resolve_mmc_dev(1);
    uint64_t start = argc > 3 ? strtoull(argv[3], NULL, 0) : 0;
    FILE *in = fopen(argv[2], "rb");
    if (!in) fail(argv[2]);
    fseek(in, 0, SEEK_END);
    uint64_t count = ((uint64_t)ftell(in) + SECTOR - 1) / SECTOR;
    rewind(in);
    uint8_t *buf = malloc(cfg.window * SECTOR);
    if (!buf) fail("malloc");
    for (uint64_t off = 0; off < count; off += cfg.window) {
        uint64_t n = count - off < cfg.window ? count - off : cfg.window;
        memset(buf, 0, n * SECTOR);   /* a final short window pads with zeros */
        if (fread(buf, 1, n * SECTOR, in) != n * SECTOR && off + n < count) fail(argv[2]);
        download("mem", stage, buf, n * SECTOR);
        snprintf(cmd, sizeof cmd, "amlmmc write %u 0x%x 0x%llx 0x%llx", cfg.mmc_dev,
                 cfg.stage_addr, (unsigned long long)(start + off),
                 (unsigned long long)n);
        run(cmd);
        progress((off + n) * SECTOR, count * SECTOR);
    }
    free(buf);
    fclose(in);
    fprintf(stderr, "\nwrote %llu sectors from %s\n", (unsigned long long)count, argv[2]);
}

/* The ROM moves memory and runs code; it cannot reach eMMC. This is the unbrick rail,
   reached by `set_usb_boot 2` then `reset`. */
static void cmd_rom(int argc, char **argv) {
    if (!is_mask_rom()) die("not in mask ROM - set_usb_boot 2, then reset", 0);
    uint32_t addr = (uint32_t)strtoull(argv[3], NULL, 0);
    if (!strcmp(argv[2], "read") && argc == 6) {
        FILE *out = fopen(argv[5], "wb");
        if (!out) fail(argv[5]);
        rom_read(addr, strtoull(argv[4], NULL, 0), out);
        if (fclose(out)) fail(argv[5]);
    } else if (!strcmp(argv[2], "write") && argc == 5) {
        size_t len;
        uint8_t *buf = slurp(argv[4], &len);
        rom_write(addr, buf, len);
        free(buf);
    } else if (!strcmp(argv[2], "run") && argc == 4) {
        uint32_t arg = addr | KEEP_POWER;
        if (libusb_control_transfer(dev, 0x40, RUN_IN_ADDR, addr >> 16, addr & 0xffff,
                                    (uint8_t *)&arg, 4, FAST_MS) != 4)
            die("rom run", 0);
    } else {
        die("usage: amlcmd rom {read <addr> <size> <out>|write <addr> <in>|run <addr>}", 0);
    }
}

static void print_link(void) {
    fprintf(stderr, "link up: %s %04x:%04x (ROM %d.%d Stage %d.%d)\n",
            is_mask_rom() ? "mask ROM" : "burning gadget", cfg.vid, cfg.pid, ident[0],
            ident[1], ident[2], ident[3]);
}

/* What a port would otherwise measure by hand, in the order it is needed. */
static void cmd_probe(void) {
    print_link();
    printf("staging 0x%x: %s\n", cfg.stage_addr,
           stage_reads_back() ? "reads back" : "no readback - set AML_STAGE_ADDR");
    uint64_t sectors = emmc_sectors();
    if (sectors) printf("boot device: %llu sectors\n", (unsigned long long)sectors);
    else puts("boot device: size refused, so a backup needs an explicit count");
    int found = discover_mmc_dev();
    if (found < 0)
        puts("eMMC: none answered, or more than one - set AML_MMC_DEV");
    else
        printf("eMMC: dev %d\n\nAML_MMC_DEV=%d AML_STAGE_ADDR=0x%x\n", found, found,
               cfg.stage_addr);
}

/* Anything the verbs do not claim is the text of a command for the box. */
static int passthrough(int argc, char **argv) {
    char line[CMD_LEN] = {0}, reply[REPLY_LEN];
    for (int i = 1; i < argc; i++) {
        if (i > 1) strncat(line, " ", sizeof line - strlen(line) - 1);
        strncat(line, argv[i], sizeof line - strlen(line) - 1);
    }
    int reboots = !strcmp(argv[1], "reset") || !strcmp(argv[1], "reboot");
    int rc = command(line, reply);
    /* A box that resets inside run_command never writes a verdict, so whatever comes
       back is stale or a lost device. Report the reset, not the debris. */
    if (reboots) {
        /* A box that resets mid-command loses the link, which is the command
           working. A verdict that came back means it did not reset. */
        if (rc < 0) {
            puts("box reset");
            return 0;
        }
        printf("%s (no reset - the box answered)\n", reply);
        return 1;
    }
    printf("%s\n", reply);
    return rc;
}

/* Catch arity before opening the device, so a typo costs nothing. */
static int check_arity(const char *act, int argc) {
    if (!strcmp(act, "read") && argc != 6)
        return misuse("amlcmd read {mem|store} <addr|part> <size> <out>");
    if (!strcmp(act, "write") && argc != 5)
        return misuse("amlcmd write {mem|store} <addr|part> <in>");
    if (!strcmp(act, "backup") && (argc < 3 || argc > 5))
        return misuse("amlcmd backup <out> [start] [count]");
    if (!strcmp(act, "restore") && (argc < 3 || argc > 4))
        return misuse("amlcmd restore <in> [start]");
    if (!strcmp(act, "probe") && argc != 2)
        return misuse("amlcmd probe");
    if (!strcmp(act, "rom") && argc < 4)
        return misuse("amlcmd rom {read <addr> <size> <out>|write <addr> <in>|run <addr>}");
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2 || !strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) {
        fputs(USAGE, stderr);
        return argc < 2 ? 2 : 0;
    }
    const char *act = argv[1];
    int bad = check_arity(act, argc);
    if (bad) return bad;

    load_cfg();
    int rc = libusb_init(NULL);
    if (rc < 0) die("libusb_init", rc);
    atexit(cleanup);

    int wait_s = !strcmp(act, "connect") ? 180 : 0;
    if (connect_box(wait_s) < 0) {
        fprintf(stderr, "no box%s\n", wait_s ? "" : " - run 'amlcmd connect' first");
        return 1;
    }
    if (is_mask_rom() && strcmp(act, "rom") && strcmp(act, "connect") &&
        strcmp(act, "status")) {
        fprintf(stderr, "in mask ROM: only `rom` reaches it, and a gadget command wedges "
                        "it. Power-cycle for the burning gadget.\n");
        return 1;
    }

    if (!strcmp(act, "connect")) {
        /* The first command a fresh gadget sees arrives with its first four bytes
           eaten. Spend that on something harmless here, so every later invocation
           gets the command it asked for. */
        char reply[REPLY_LEN];
        if (!is_mask_rom()) command("printenv upgrade_step", reply);
    }

    if (!strcmp(act, "connect") || !strcmp(act, "status")) print_link();
    else if (!strcmp(act, "probe"))   cmd_probe();
    else if (!strcmp(act, "drain"))   printf("flushed %d stranded bytes\n", drain_in());
    else if (!strcmp(act, "rom"))     cmd_rom(argc, argv);
    else if (!strcmp(act, "read"))    cmd_read(argv);
    else if (!strcmp(act, "write"))   cmd_write(argv);
    else if (!strcmp(act, "backup"))  cmd_backup(argc, argv);
    else if (!strcmp(act, "restore")) cmd_restore(argc, argv);
    else                              return passthrough(argc, argv);
    return 0;
}
