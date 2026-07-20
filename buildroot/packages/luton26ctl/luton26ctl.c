/*
 * luton26ctl - minimal register-level diagnostic tool for the
 * Vitesse/Microchip Luton26 switch ASIC (VSC7425/VSC7427) used in the
 * MS220-8(P)/24(P) and MS22(P) switches.
 *
 * Register offsets come from Microchip's MIT-licensed MESA switch API
 * (github.com/microchip-ung/mesa, base/luton26/), and have been validated
 * against real MS220-24P hardware: CHIP_ID decodes to PART_ID 0x7427 as
 * expected for VSC7427.
 *
 * Read-only by design (opens /dev/mem O_RDONLY) - this is a probing tool
 * to validate the register map before any write-capable driver code is
 * written against it.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>

#define IO_ORIGIN1         0x60000000UL
#define DEVCPU_GCB_BASE    (IO_ORIGIN1 + 0x00070000UL)
#define DEV_0_BASE         (IO_ORIGIN1 + 0x001e0000UL)
#define DEV_STRIDE         0x00010000UL
#define NUM_DEV            26

/* DEVCPU_GCB:CHIP_REGS:CHIP_ID, register index 0x2 (word-addressed) */
#define CHIP_ID_OFFSET            (0x2 << 2)
/* DEV:PCS1G_CFG_STATUS:PCS1G_LINK_STATUS, register index 0x1a */
#define PCS1G_LINK_STATUS_OFFSET  (0x1a << 2)

#define HOST_PAGE_SIZE 4096UL

static volatile uint32_t *map_phys(int fd, unsigned long phys_addr, size_t len, void **map_base, size_t *map_len)
{
    unsigned long page_base = phys_addr & ~(HOST_PAGE_SIZE - 1);
    unsigned long page_off = phys_addr - page_base;
    size_t total = len + page_off;
    void *m = mmap(NULL, total, PROT_READ, MAP_SHARED, fd, page_base);

    if (m == MAP_FAILED)
        return NULL;

    *map_base = m;
    *map_len = total;
    return (volatile uint32_t *)((char *)m + page_off);
}

static int cmd_chipid(int fd)
{
    void *map_base;
    size_t map_len;
    volatile uint32_t *reg = map_phys(fd, DEVCPU_GCB_BASE + CHIP_ID_OFFSET, sizeof(uint32_t), &map_base, &map_len);
    uint32_t val, rev, part, mfg, one;

    if (!reg) {
        perror("mmap CHIP_ID");
        return 1;
    }

    val = *reg;
    munmap(map_base, map_len);

    if (val == 0 || val == 0xffffffffUL) {
        fprintf(stderr, "CHIP_ID read error: 0x%08x (bad address or CPU interface error)\n", val);
        return 1;
    }

    rev  = (val >> 28) & 0xf;
    part = (val >> 12) & 0xffff;
    mfg  = (val >> 1) & 0x7ff;
    one  = val & 0x1;

    printf("CHIP_ID raw:  0x%08x\n", val);
    printf("PART_ID:      0x%04x (VSC%04x)\n", part, part);
    printf("REV_ID:       %u\n", rev);
    printf("MFG_ID:       0x%03x\n", mfg);
    printf("ONE bit:      %u (%s)\n", one, one ? "ok" : "SUSPECT - expected 1");

    return 0;
}

static int cmd_ports(int fd)
{
    void *map_base;
    size_t map_len;
    volatile uint32_t *base = map_phys(fd, DEV_0_BASE, NUM_DEV * DEV_STRIDE, &map_base, &map_len);
    int i;

    if (!base) {
        perror("mmap DEV blocks");
        return 1;
    }

    printf("%-7s %-10s %-6s %-6s %-6s\n", "DEV", "raw", "sync", "link", "sigdet");
    for (i = 0; i < NUM_DEV; i++) {
        volatile uint32_t *reg =
            (volatile uint32_t *)((char *)base + i * DEV_STRIDE + PCS1G_LINK_STATUS_OFFSET);
        uint32_t val = *reg;

        printf("DEV_%-3d 0x%08x %-6s %-6s %-6s\n", i, val,
               (val & 0x001) ? "sync" : "-",
               (val & 0x010) ? "link" : "-",
               (val & 0x100) ? "sig"  : "-");
    }

    munmap(map_base, map_len);
    return 0;
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s <command>\n"
        "  chipid   decode DEVCPU_GCB:CHIP_REGS:CHIP_ID\n"
        "  ports    dump PCS1G_LINK_STATUS for DEV_0..DEV_%d\n",
        prog, NUM_DEV - 1);
}

int main(int argc, char **argv)
{
    int fd, rc;

    if (argc != 2) {
        usage(argv[0]);
        return 1;
    }

    fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    if (strcmp(argv[1], "chipid") == 0) {
        rc = cmd_chipid(fd);
    } else if (strcmp(argv[1], "ports") == 0) {
        rc = cmd_ports(fd);
    } else {
        usage(argv[0]);
        rc = 1;
    }

    close(fd);
    return rc;
}
