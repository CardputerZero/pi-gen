/*
 * CardputerZero Early Splash - bare SPI framebuffer writer
 * Runs as initramfs /init, directly writes BCM2835 SPI registers
 * to display a logo on ST7789 (320x170) before any driver loads.
 *
 * Hardware config (from DT overlay):
 *   SPI0, CS0 (GPIO8), DC=GPIO25
 *   SPI freq: ~32MHz (divider=8 from 250MHz core)
 *   Display: 320x170, rotate=90, RAM y-offset=35
 */

#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>

#define BCM2835_PERI_BASE  0x20000000  /* CM0 = BCM2835 */
#define GPIO_BASE          (BCM2835_PERI_BASE + 0x200000)
#define SPI0_BASE          (BCM2835_PERI_BASE + 0x204000)

/* GPIO registers */
#define GPFSEL0   0x00
#define GPFSEL2   0x08
#define GPSET0    0x1C
#define GPCLR0    0x28

/* SPI registers */
#define SPI_CS    0x00
#define SPI_FIFO  0x04
#define SPI_CLK   0x08

/* SPI CS register bits */
#define SPI_CS_TA       (1 << 7)
#define SPI_CS_DONE     (1 << 16)
#define SPI_CS_TXD      (1 << 18)
#define SPI_CS_CLEAR_TX (1 << 4)
#define SPI_CS_CLEAR_RX (1 << 5)

/* GPIO pins */
#define PIN_DC   25
#define PIN_CS   8

/* ST7789 commands */
#define ST7789_SLPOUT   0x11
#define ST7789_DISPON   0x29
#define ST7789_CASET    0x2A
#define ST7789_RASET    0x2B
#define ST7789_RAMWR    0x2C
#define ST7789_MADCTL   0x36
#define ST7789_COLMOD   0x3A

static volatile uint32_t *gpio_map;
static volatile uint32_t *spi_map;

static void gpio_set(int pin) { gpio_map[GPSET0/4] = 1 << pin; }
static void gpio_clr(int pin) { gpio_map[GPCLR0/4] = 1 << pin; }

static void gpio_fsel(int pin, int mode) {
    int reg = pin / 10;
    int shift = (pin % 10) * 3;
    uint32_t val = gpio_map[reg];
    val &= ~(7 << shift);
    val |= (mode << shift);
    gpio_map[reg] = val;
}

static void spi_init(void) {
    /* Set GPIO 8 (CE0), 9 (MISO), 10 (MOSI), 11 (SCLK) to ALT0 */
    gpio_fsel(8, 4);   /* CE0 = ALT0 */
    gpio_fsel(9, 4);   /* MISO = ALT0 */
    gpio_fsel(10, 4);  /* MOSI = ALT0 */
    gpio_fsel(11, 4);  /* SCLK = ALT0 */
    /* GPIO 25 = output (DC) */
    gpio_fsel(PIN_DC, 1);

    /* SPI clock divider: 250MHz / 8 = ~31MHz */
    spi_map[SPI_CLK/4] = 8;
    /* Clear FIFOs */
    spi_map[SPI_CS/4] = SPI_CS_CLEAR_TX | SPI_CS_CLEAR_RX;
}

static void spi_transfer(const uint8_t *data, int len) {
    spi_map[SPI_CS/4] = SPI_CS_TA | SPI_CS_CLEAR_TX | SPI_CS_CLEAR_RX;
    for (int i = 0; i < len; i++) {
        while (!(spi_map[SPI_CS/4] & SPI_CS_TXD)) {}
        spi_map[SPI_FIFO/4] = data[i];
    }
    while (!(spi_map[SPI_CS/4] & SPI_CS_DONE)) {}
    spi_map[SPI_CS/4] = 0;
}

static void st7789_cmd(uint8_t cmd) {
    gpio_clr(PIN_DC);  /* DC=0 for command */
    spi_transfer(&cmd, 1);
}

static void st7789_data(const uint8_t *data, int len) {
    gpio_set(PIN_DC);  /* DC=1 for data */
    spi_transfer(data, len);
}

static void st7789_cmd_data(uint8_t cmd, const uint8_t *data, int len) {
    st7789_cmd(cmd);
    if (len > 0) st7789_data(data, len);
}

static void delay_ms(int ms) {
    usleep(ms * 1000);
}

static void st7789_init(void) {
    /* Sleep out */
    st7789_cmd(ST7789_SLPOUT);
    delay_ms(120);

    /* MADCTL: rotate 90° (MX+MV), BGR */
    uint8_t madctl = 0x60;  /* MV=1, MX=1 for 90° rotation */
    st7789_cmd_data(ST7789_MADCTL, &madctl, 1);

    /* Color mode: 16-bit RGB565 */
    uint8_t colmod = 0x55;
    st7789_cmd_data(ST7789_COLMOD, &colmod, 1);

    /* Display on */
    st7789_cmd(ST7789_DISPON);
    delay_ms(20);
}

static void st7789_set_window(uint16_t x0, uint16_t y0, uint16_t x1, uint16_t y1) {
    /* Apply RAM y-offset of 35 */
    y0 += 35; y1 += 35;
    uint8_t ca[] = {x0>>8, x0&0xFF, x1>>8, x1&0xFF};
    uint8_t ra[] = {y0>>8, y0&0xFF, y1>>8, y1&0xFF};
    st7789_cmd_data(ST7789_CASET, ca, 4);
    st7789_cmd_data(ST7789_RASET, ra, 4);
    st7789_cmd(ST7789_RAMWR);
}

static void fill_screen(uint16_t color) {
    st7789_set_window(0, 0, 319, 169);
    gpio_set(PIN_DC);
    /* Fill 320x170 pixels = 108800 bytes */
    uint8_t hi = color >> 8, lo = color & 0xFF;
    spi_map[SPI_CS/4] = SPI_CS_TA | SPI_CS_CLEAR_TX | SPI_CS_CLEAR_RX;
    for (int i = 0; i < 320*170; i++) {
        while (!(spi_map[SPI_CS/4] & SPI_CS_TXD)) {}
        spi_map[SPI_FIFO/4] = hi;
        while (!(spi_map[SPI_CS/4] & SPI_CS_TXD)) {}
        spi_map[SPI_FIFO/4] = lo;
    }
    while (!(spi_map[SPI_CS/4] & SPI_CS_DONE)) {}
    spi_map[SPI_CS/4] = 0;
}

int main(void) {
    int fd;

    /* Mount proc for later exec */
    mount("proc", "/proc", "proc", 0, NULL);

    /* Map GPIO and SPI registers */
    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) goto chain;

    gpio_map = (volatile uint32_t *)mmap(NULL, 4096, PROT_READ|PROT_WRITE,
                                          MAP_SHARED, fd, GPIO_BASE);
    spi_map = (volatile uint32_t *)mmap(NULL, 4096, PROT_READ|PROT_WRITE,
                                         MAP_SHARED, fd, SPI0_BASE);
    close(fd);

    if (gpio_map == MAP_FAILED || spi_map == MAP_FAILED) goto chain;

    /* Init SPI and display */
    spi_init();
    st7789_init();

    /* Fill screen black then draw a simple "ZERO" indicator */
    fill_screen(0x001F);  /* Blue screen as splash */


chain:
    /* Chain to real init */
    execl("/sbin/init", "/sbin/init", NULL);
    /* Fallback */
    execl("/bin/sh", "/bin/sh", NULL);
    return 1;
}
