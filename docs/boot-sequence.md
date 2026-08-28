# S.T.U.N. Runner 68010 boot / initialisation sequence

Traced from the 68010 program in Ghidra (project Disassembly, program
`stunrun_68k.bin`, folder /stunrunner). Function names below are the ones now
set in Ghidra. Addresses are 68k addresses; register/latch semantics are from
`docs/hardware.md`. "Word N of ADSP data RAM" = 68k address 808000 + 2N.

Two things an RTL implementer should know up front:

1. There are **two vector tables**. The ROM table at 0 is used only by the
   first stage and by self-test (VBR = 0). The game copies **VBR = 0x20000**
   and uses the table there; the "real" IRQ handlers are the `Game*` ones
   (section 9), not `Irq2Adsp`/`Irq3Gsp`/... at 0x7xx.
2. Before the GSP program runs, the 68k **draws the boot text itself** through
   the GSP host port (expander region) and has already turned the display on
   (DPYCTL.ENV = 1). "STUN RUNNER / PROCESSING BACKGROUNDS / DOWNLOADING*GSP /
   DOWNLOADING*ADSP" must be visible with the stage-1 video timing.

---

## 1. Power-on: `reset_entry` (0x216)

Reset vector at 0: SSP = 0xffffc000, PC = 0x216.

| addr | action | RTL note |
|---|---|---|
| 0x216 | `lea 0,A0; movea.l (A0),SP; movec A0,VBR` | 68010 only (MOVEC) |
| 0x222 | `clr.w 60c000` | IRQ5 ack |
| 0x228 | `RESET` instruction | asserts /RESET to peripherals for 124 clocks; core should at least tolerate it |
| 0x22a | `clr.w 608000` | watchdog kick |
| 0x230 | `clr.w 60c000` | IRQ5 ack |
| 0x236 | `clr.w 818060` | clear ADSP->68k IRQ2 |
| 0x23c | `move.w 604000,D0` | **JSA sound-board reset** (read) |
| 0x242 | `move.b 600000,D0` | drain sound response, clears IRQ4 |
| 0x248 | `clr.w 840000`, `clr.w 84c000` | MSP-board latches; unmapped on stunrun, must be harmless (no bus error) |
| 0x254 | `btst #5,60c001` (port 0 bit 5, self-test) | 1 = game, 0 = self-test |

**Self-test decision.** Bit 5 = 0 (test switch on) -> 0x2a0: if diag jumper
(port 0 bit 0) = 1 -> `SelfTestEntry` (0x8fee), else 0x506c (a variant of the
same). Bit 5 = 1 -> game path at 0x260. The self-test menu selector is the
**SW1 byte** (`move.b 60c000,D0` at 0x9010: raw 0x00 = all-On default ->
0x9da4 "default test"; otherwise `~SW1 & 0x3f` picks a test). The self-test's
`SelfTestWaitVblank` (0x13ec) and 0x1368 re-check bit 5 every frame and jump
to 0x260 (game) when the switch is turned off.

**Game path, stage 1 (VBR = 0, IRQ mask 7, SR = 0x2f00):**

1. `Stage1GspInit` (0x3f8), see section 2.1.
2. `Stage1ColourBars` (0x570): 256-entry ramp palette written through
   f5000000/f5800000 (palette bank bits both 0), LED sel 7 off/on, finescroll 0
   then 7.
3. `clr.w 608000`; `GspExpanderFill(D0=0)` (0x636): `control_lo[0]`
   (f4000000) = 0, then 0x6000 writes of 0xffff to the 2bpp expander region at
   GSP 0x02000000 (= 0x30000 pixels cleared to colour 0), watchdog kick every
   256 words.
4. `clr.w 608000`; **VBR = 0x20000**, SP = [0x20000] = 0x00000000 (stack wraps
   to top of work RAM at ffxxxx on the 24-bit bus), `clr.w 60c000`,
   `jmp [0x20004]` = **`GameInit` (0x212ae)**.

No 68k work-RAM test is performed on the game path (RAM tests live in the
self-test only). Work RAM ff8000-ffffff is zeroed by `GameInit`.

**Watchdog (608000, write).** Kicked at every step above and inside every long
loop (VRAM fill: every 256 HSTDATA writes). Longest gaps with no kick during a
normal boot: the GSP download (12184 HSTDATA writes, ~40 ms) and the ADSP
download (2728 long writes, ~15 ms). Error paths deliberately stop kicking
(`HaltForWatchdog` 0x21286 = `stop #0x2700`) and rely on the watchdog to
restart the machine, so the core **must implement the watchdog reset**. MAME's
`watchdog_timer_device` default with no period given is 3 s; anything >= 100 ms
and <= a few seconds is safe.

### 1.1 `GameInit` (0x212ae)

```
clr.w 608000 ; SR=2700 ; move.w #4,818040   (818040 is NOT in the MAME map: unmapped write, ignore)
if [ff8018] == 0x31415982 (warm restart magic):        ; only true after a soft reset
    clr.w 604008 ; clr.w 60401a     -> NWR sel4=0 (ZP1=0), sel5=1 (ZP2=1): ZRAM write-enable
    addq.b #1,ff4b90                 ; error count in EEPROM
    clr.w 604008 ; clr.w 60401a ; call 0x2efb6 (recompute EEPROM checksum)
zero work RAM ff8000-ffffff (0x2000 longs) ; kick watchdog ; [ff8018] = 0x31415982
GspVramClear (0x223f4): HSTADR=ff800000, HSTCTL=b800, 5 x 0x10000 clr.l to HSTDATA = 0xA0000 words
                        (VRAM + mirror wrap), watchdog kick per 0x10000
MspVramClear (0x22428): HSTADR c04002=0, c04008=b800, 0x8000 clr.l to c0400c   (MSP absent: must be no-op, no bus error)
ZramService init (0x20702/0x20708): reads coin/option bytes from ZRAM ff4001.. (odd bytes = 200E timekeeper)
GameMainLoop (0x24306) -> never returns; HaltForWatchdog if it does
```

`GameMainLoop` first calls **`HardwareInit` (0x2c0d2)** which is the real
initialisation (section 1.2), then `SoundReset`, options, then loops. Each
loop iteration: if port 0 bit 5 == 0 (test switch) -> `GameSoftReset`
(0x2128a: VBR=0, SP=[0], jump [4] = reset_entry, so the machine reboots into
self-test); `SoundQueueFlush`; state machine; most states end in
`FrameUpdate` (section 3.3).

### 1.2 `HardwareInit` (0x2c0d2) - order of operations

```
1  ff9bb6/8=0, ff9bba=3 ; kick WD
2  GspResetAndInit (0x22382)                       section 2.1 (game variant)
3  kick WD ; GspClearScreen (0x22468 -> GspExpanderFill2, colour 0)
4  kick WD ; GspPrintText(x=40,y=20,col=ff,"STUN RUNNER")           text drawn by 68k via expander
5  SoundReset (0x300f8)                            section 4
6  kick WD ; GspPrintText(40,30,"PROCESSING BACKGROUNDS") ; 0x2d7c2
7  AdcStart (0x23e06): b80001 <- 0x48 then 0x00   (channel 0, START pulse; byte writes to the low byte)
8  kick WD ; AdspHoldReset (0x2141a):
      clr.w 81801c  sel6=1  /HALT=1  (not halted)
      clr.w 81800e  sel7=0  RESET asserted (hold ADSP in reset)
      clr.w 818060  clear IRQ2
      clr.w 818014  sel2=1  (unlisted in hardware.md; MAME ignores)
      move.w #4,818040                            (unmapped, ignore)
9  kick WD ; SetSr(0x2000)  -> ALL interrupt levels enabled from here on
10 GspPrintText(40,80,"DOWNLOADING*GSP")
11 SW1 bit 6 of the high byte (word bit 14, SW1 #2) set ? GspLoadFromSerial : GspLoadFromRom([0x17004]=0x1907c)   section 2.2
12 move.w #0x7800,c00008 ; move.w #0x3800,c00008  -> HLT=0, GSP starts executing at its reset vector (ffffffe0, inside block 3 of the image)
13 kick WD ; GspPrintText(40,100,"DOWNLOADING*ADSP")
14 SW1 bit 4 of the high byte (word bit 12, SW1 #4) set ? AdspLoadFromSerial : AdspLoadFromRom([0x17000]=0x1702e)  section 3.1
15 ADSP release sequence (exact order):
      clr.w 81800e   sel7=0  RESET asserted
      clr.w 818008   sel4=0  (unlisted, ignore)
      clr.w 81800a   sel5=0  /BR=0 (bus request, ADSP off the bus)
      move.w #ffff,80bffe    data word 0x1fff = 0xffff  (the "trigger" word; also MAME's IRQ-trigger hint)
      clr.w 818060           clear IRQ2
      ff9bb4=0 (ADSP-done flag) ; ff9bc8=1 (first frame pending)
      clr.w 818014   sel2=1
      clr.w 818016   sel3=1  SOM bank = 1 (68k sees bank 1), shadow ff9bb2=1
      clr.w 81801e   sel7=1  RESET released
      clr.w 818018   sel4=1
      clr.w 81801a   sel5=1  /BR=1 (bus released)
      clr.w 81801c   sel6=1  /HALT=1  -> ADSP runs from PC 0
16 constants -> ffdb04.. ; 0x2ed1a "PROCESSING BACKGROUNDS" object lists (kicks WD between blocks)
17 GspFrameBegin (0x2f126)      <- FIRST wait on the GSP, section 2.3
18 GspSendCameraBlock ; 0x2f6be/0x2f6e6/0x2f742 (ROM -> GSP data, 3 palettes + objects 3..12 at GSP fff2b760 + n*0x2060)
19 GspFrameEnd(-1) (0x2f1be)    <- second wait on the GSP ("END GSP BUFFER"), section 2.3
```

`FrameUpdate`'s first call (state 0x29/0x3c from the main loop) then performs
the first ADSP handshake (section 3.3).

---

## 2. GSP (TMS34010) bring-up

Host port: HSTADRL = c00000 (+2 for the low word of a `move.l` to c00002),
HSTADRH = c00004, HSTCTL = c00008, HSTDATA = c0000c. The code always writes
the 32-bit GSP bit address as one `move.l` to **c00002** (= HSTADRH then
HSTADRL, i.e. high word at c00002/c00004... in practice: bytes c00002-3 =
address bits 31:16 -> HSTADRH, c00004-5 = bits 15:0 -> HSTADRL).

### 2.1 GSP register initialisation (`Stage1GspInit` 0x3f8; game copy `GspResetAndInit` 0x22382)

```
clr.w 60400c            NWR sel6=0  -> /GSPRES asserted (GSP in reset)
delay 0x190 (stage 1) / 0x96 (game) loop iterations
clr.w 60401c            NWR sel6=1  -> /GSPRES released (GSP comes up HALTED: HLT bit set by reset)
move.w #0xa000,c00008   HSTCTLH = a0: HLT=1, LBL=1 ; HSTCTLL = 00      (stage 1 only)
GspWriteBitfieldReg(2): HSTDATA write of 0xb800 to GSP I/O reg c0000100 (HSTCTLH) -> HLT,LBL,INCR,INCW
GspWriteVideoRegs: 8 I/O registers via HSTADR/HSTDATA (tables 0x2b8 stage 1, 0x215aa game):
      c0000070 VTOTAL = 0x105
      c0000060 VSBLNK = 0xf8  (stage 1)   /  0x103 (game)
      c0000050 VEBLNK = 0x13
      c0000040 VESYNC = 0x04
      c0000030 HTOTAL = 0x13c
      c0000020 HSBLNK = 0x137
      c0000010 HEBLNK = 0x37
      c0000000 HESYNC = 0x13
GspSetPsize1:  c0000150 PSIZE  = 1
GspSetDpystrt: c0000090 DPYSTRT = 0xffff ; f4800000 control_hi sel0 <- 0 (SR-transfer disable)
GspWriteBitfieldReg(1): c00000b0 CONTROL = 0x0008
GspWriteBitfieldReg(0): c0000080 DPYCTL  = 0xf010  (ENV,NIL,DXV,SRT set, DUDATE=4)  -> display ON now
GspGreyPalette: HSTCTL |= 0x1800 ; f4800020/30 (stage 1: bank bits 0,0) or f48000a0/b0 (game: bank bits 1,1 = bank 3)
      256 words to f5000000 (lo: R=G=i) and 256 to f5800000 (hi: B=i)
GspSetFinescroll7: f4800010 <- 0, f4800090 <- 0xffff  (sel1 value=data&7 -> 7)   [game writes 0 three times -> finescroll 0]
stage 1 only: f4800010<-0, f4800090<-ffff again ; GspVramFill(0): HSTADR=ff800000, 0x384*0x100 = 0x38400 words of 0 (450 KB), WD kick per 256
game only:    0x445f0: LED sel7 0 then 1; HSTADR left at 0x02000000
```

HSTCTL bits actually used by the game (every write site checked):
`0xa000`, `0xb800` (HLT|LBL|INCR|INCW), `|= 0x1800` (INCR|INCW on),
`&= 0xe7ff` (INCR|INCW off, used by `GspPrintText`), `0x7800` then `0x3800`
(release HLT; 0x4000 = CF cache flush), `&= 0xff7f` (clear INTOUT, in the IRQ3
handler; note this is a read-modify-write of the whole HSTCTL word), and in
self-test `&= 0x7fff`. **INTIN (bit 3), MSGIN and NMI (bit 8) are never
written by the game.** The GSP is started only by clearing HLT; it runs from
its own reset vector ffffffe0.

### 2.2 GSP program download (`GspLoadFromRom` 0x2fdd0, `GspLoadBlock` 0x2fe0c)

Source: ROM pointer at 0x17004 -> image at **0x1907c-0x1efd3**. HSTCTL =
0xb800 (post-increment on write). Format: `long nblocks`, then per block
`long gsp_bit_address, long bit_length, data...`. Each data longword is
written **low 16 bits first, then high 16 bits** (`GspWriteLongLoHi`), i.e.
GSP word[addr] = low half, word[addr+0x10] = high half. A trailing remainder of
exactly 16 bits is written as one word; any other remainder ->
`HaltForWatchdog`.

| block | GSP bit address | bits | 16-bit words | ROM |
|---|---|---|---|---|
| 0 | fff40000 | 0x1a170 | 6679 | 19088-1c4b7 |
| 1 | fff5a170 | 0x02780 | 632 | 1c4c0-1c9af |
| 2 | fff5c8f0 | 0x12c90 | 4809 | 1c9b8-1ef4b |
| 3 | fffffc00 | 0x00400 | 64 (trap/reset vectors, includes ffffffe0) | 1ef54-1efd3 |

Total 12184 words = 24368 bytes, all inside the VRAM mirror (fff40000 =
ffb40000 in the 512 KB array). Then `c00008 <- 0x7800, 0x3800` (HLT off).

SW1 word bit 14 selects `GspLoadFromSerial` (0x2fcc0): waits on DUART channel
B for ten 'S' (0x53) bytes then 'G' (0x47) and streams the same block format
from the serial port; never taken with the default DIPs (all On = 0).

### 2.3 What the 68k waits for after releasing the GSP

There is **no poll of a "GSP alive" word right after HLT release**; the ADSP
download and object processing happen first. The first synchronisation is
`GspFrameBegin` (0x2f126), reused every frame:

```
idx = ffdb3a ^= 1                                    two command buffers
table 0x4a88c: idx0: flag fff9fc00, buffer fff9fc10 ; idx1: flag fffcfc00, buffer fffcfc10   (GSP bit addresses)
HSTADR = flag ; if HSTDATA read != 0:               GSP has not consumed that buffer yet
      ffdb48 = 0
      GspWaitIrq3("OUT OF SYNC"):  loop up to 0x80000 times { GspFeedDataStream(5); kick WD }
                                   until ffdb48 != 0   (set to 0xffff by GameIrq3Gsp = INTOUT)
                                   timeout -> TimeoutFatalWithBanner(0xc) = "GSP TIME OUT ERROR" + "OUT OF SYNC"
      re-read flag ; still != 0 -> FatalError(8) "GSP HANDSHAKE ERROR" -> HaltForWatchdog
HSTADR = buffer                                       caller now streams the frame's command list via HSTDATA
```

`GspFrameEnd(v)` (0x2f1be): `GspWaitIrq3("END GSP BUFFER")` (same wait),
writes terminator 0xffff to HSTDATA, sets HSTADR = flag address, `ffdb48 = 0`,
writes `v` (0xffff from HardwareInit; the frame's value later) to the flag
word = "buffer ready", records the tick counter. So the contract the GSP
program must honour (and an RTL trace should show): the 68k writes a
non-zero flag word at fff9fc00/fffcfc00; the GSP processes the command list
at +0x10, **clears the flag word to 0 and sets HSTCTLL.INTOUT** (68k IRQ3).
The 68k clears INTOUT itself (`andi.w #0xff7f,c00008`).

Timeout scale: 0x80000 iterations, each running `GspFeedDataStream` (five
compressed-stream items -> several HSTDATA writes) = several seconds. At boot
the VRAM was zero-filled, so the very first `GspFrameBegin` sees flag = 0 and
does not wait; the first real wait is `GspFrameEnd(-1)`, which waits for the
GSP's first INTOUT. **A GSP that never raises INTOUT hangs the boot at 0x2fc60
until "GSP TIME OUT ERROR".**

`GspFeedDataStream` (0x22766) is the background loader: it decompresses ROM
data blocks (pointer table at 0xbfe00 indexed by ff9bcc) into GSP memory
starting at ffe00000, resuming at the HSTADR saved in ff9bd4; it runs from
every wait loop.

---

## 3. ADSP-2100 bring-up and per-frame handshake

### 3.1 Program download (`AdspLoadFromRom` 0x2d2e0)

Before writing: `clr.w 818008` (sel4=0), `clr.w 81800a` (/BR=0),
`clr.w 81800e` (RESET asserted), `clr.w 81800c` (/HALT=0). Source: pointer at
0x17000 -> image at **0x1702e-0x1907b**. Format: `byte flag` (0 = block,
0xff = end), `word pm_address`, `word count`, then `count` x 3 bytes; each
24-bit word is written as one 68k **long** to `800000 + pm_address*4`
(even word = bits 23:16, odd word = bits 15:0), sequentially. 17 blocks, 2728
words, covering PM 0x0000-0x083b ... 0x089a and 0x1029-0x1235 (68k
800000-80226b and 8040a4-8048d7). No watchdog kick during the download. After
the end flag: `clr.w 818018` (sel4=1), `clr.w 81801a` (/BR=1),
`clr.w 81801e` (RESET released). /HALT stays 0 until `HardwareInit` step 15.
There is **no read-back verification** of program RAM.

`AdspLoadFromSerial` (0x2d1d4, SW1 word bit 12) does the same from DUART B
after ten 'A' (0x41) bytes and a 'G'.

### 3.2 Data RAM layout used by the 68k (16-bit words, 808000 + 2N)

| word | 68k addr | written by | meaning |
|---|---|---|---|
| 0x0a00.. | 809400.. | `AdspStartFrameFull`/`AdspKickFrameIncremental` via 0x2e1ec | object list; terminated by 0xffff; > 0x15e3 words -> `HaltForWatchdog` |
| 0x1fe3 | 80bfc6 | ADSP (read by `AdspIrqService`) | status/"more work" flag; 68k clears it |
| 0x1fe4-0x1fe7 | 80bfc8-80bfce | 68k | constants from ROM 0x48e2a/0x48e26/0x48e2c/0x48e2e |
| 0x1fe9-0x1fee | 80bfd2-80bfdc | 68k | 3 longs: camera position (ffdaf8/ffdafc/ffdb00; init 0, -0x5a0, 0) |
| 0x1fef-0x1ff4 | 80bfde-80bfe8 | 68k | 3 rotation words + 3 constants (0x4a82a..) |
| 0x1ff5-0x1ffd | 80bfea-80bffa | 68k | 3x3 matrix (0x22dd6 from ffdb04) |
| 0x1ffe | 80bffc | 68k | constant from ROM 0x48de8 |
| 0x1fff | 80bffe | 68k | **trigger**: 0xffff once at init (before the ADSP is released), 0x0000 at every frame start |

The game **never reads 838000** (ADSP IRQ state/XFLAG); completion is
signalled only through IRQ2.

### 3.3 Per-frame handshake

```
GameIrq2Adsp (0x213fe):  clr.w 818060 (ack) ; AdspIrqService ; clr.w 818010 (LED sel0=1) ; rte
AdspIrqService (0x2e418): clr.w 81800a (/BR=0) ; clr.w 818008        halt ADSP on the bus
                          if [80bfc6] != 0: ff9c74 ? ff9c72=1 : [80bfc6]=0
                          else            : ff9bb4 = 1 (frame done) ; ff9c72 = 0
                          clr.w 818018 ; clr.w 81801a (/BR=1)         release
FrameUpdate (0x2c372):    kick WD
   if ff9bc8 == 0 (not first frame):
       loop until ff9bb4 != 0 { GspFeedDataStream(5); count++; if count > 100000: FatalError(0xb) "ADSP TIME OUT ERROR"; kick WD }
       ff9bb4 = 0
       toggle SOM bank: ff9bb2 ? (clr.w 818006 = bank 0, ff9bb2=0) : (clr.w 818016 = bank 1, ff9bb2=1)
   clr.w 604010 (NWR sel0=1, CR2)
   AdspKickFrameIncremental / AdspStartFrameFull:  clr.w 81800a, clr.w 818008 (halt via BR) ; write words 0x1fe4-0x1ffe and the object list ;
                                                   clr.w 80bffe (trigger = 0) ; ff9c72 = 0 ; clr.w 818018, clr.w 81801a (release) ; ff9c76 = 1
   clr.w 818000 (LED sel0=0)
   if ff9bc8 == 0: GspFrameBegin ; GspSendCameraBlock (0x44 words) ; ... ; SomCopyToGsp(810000) ; ... ; clr.w 818002
```

`SomCopyToGsp` (0x2f0ae): HSTDATA <- 0x7000, then `count = [810000]`, copies
`count` words from 810002.. to HSTDATA (`GspWriteWords`), and requires the last
copied word `[810000 + 2*count]` to be **0xffff**, else `HaltForWatchdog`. The
68k therefore reads the SOM bank selected by 818006/818016 while the ADSP fills
the other one.

The ADSP program is expected to: poll data word 0x1fff for 0 (frame start),
transform the object list at 0xa00.., emit the result into the SOM bank it
does not own with a leading count and trailing 0xffff, write /GINT (data
0x2006) to raise IRQ2. It must tolerate being bus-requested (/BR) at any time
because the 68k halts it around every data-RAM access.

---

## 4. Sound board (JSA II) handshake

Hardware: read 604000 = 6502 reset + response latch clear; 600000 write =
command (D15:8), read = response (clears IRQ4).

```
JsaHardwareReset (0x23fa2): move.w 604000,D1 ; move.b 600000,D1 ; clear queue pointer ff9474
SoundReset (0x300f8):       JsaHardwareReset ; ffdb5c = 0xb4 (180) ; ffdb5e = 0 ; ffdb62 = 0 ; queue state reset
GameIrq4Sound = vector 0x23f24 (inside SoundResponseIrqHandler 0x23f0c):
                            move.b 600000 -> 16-byte ring at ff9478 (head ff9471, tail ff9470), or to *[ff9474] if set ; rte
SoundSendCmd(c) (0x23ede):  SR=2400 ; if a80000 bit 15 == 1: move.b c,600000 ; return 1  else return 0 (one attempt)
SoundWatchdog (0x3001e), called once per main-loop iteration (~ once per frame):
   b = SoundPopResponse()                       (0xffff if empty)
   if b valid:
      if ffdb5c != 0 (reset pending): b == 0xff -> ffdb5c = 0            else -> SoundReset
      elif ffdb5e != 0 (ping pending): (b & 7) == 0 -> ffdb5e = 0       else -> SoundReset
      else (unsolicited byte)                                               -> SoundReset
   if ffdb5c: if --ffdb5c reaches 0 -> SoundReset            (no 0xff within 180 iterations)
   elif ffdb5e: if --ffdb5e reaches 0 -> SoundReset          (no ping reply within 30 iterations)
   else: if --ffdb60 < 0: ok = SoundSendCmd(7) ; ok ? (ffdb5e = 0x1e, ffdb60 = 0xf0, ffdb62 = 0)
                                                    : (if ++ffdb62 > 0xb4 -> SoundReset else ffdb60 = 0)
```

Expected 6502 behaviour: after reset, send **0xff** (within ~3 s); answer
command **0x07** with a byte whose **bits 2:0 are 0** within 30 frames; never
send anything unsolicited. There is no "sound board bad" message; a dead board
just gets reset every 180 frames forever and the game keeps running. Every
sound effect is a `SoundSendCmd` from `SoundQueueFlush` (0x3013c), three
queued bytes per frame. `SoundSendCmd` only writes if **a80000 bit 15 reads 1**
(hardware.md says bits 3-15 read 1: keep it that way, or sound is silent).

The self-test's sound check (0x8db2) is stricter: read 604000, wait 180
VBLANKs (`SelfTestWaitVblank`), read 600000 and require 0xff (else message
0x90), then send 0x07, wait 2 VBLANKs, display the reply.

---

## 5. Inputs, ADC and coins

- **Port 0 (60c000)**: byte 60c001 = IN0, byte 60c000 = SW1. Game reads:
  bit 5 (self-test, every main-loop pass -> `GameSoftReset`), bit 4 (ADC EOC,
  spin loop), bits 7/6 (coins) and SW1 bits 14/12 (serial download, boot
  only). Bit 2 (VBLANK) is read **only by the self-test** (`SelfTestWaitVblank`:
  waits for bit 2 = 1 then for bit 2 = 0, i.e. the start of vertical blank).
- **a80000**: bit 0 button 1, bit 1 button 2, bit 2 start (all active low,
  read as `btst #n,a80001`); bit 15 = sound-command-ready (see section 4).
  Writes to a80000 (0x0000/0x0100, /WR1 latch, 0x46a70) are LEDs.
- **ADC0809**: `GameIrq5Timer` (0x222da, 244 Hz) -> `TimerTickService`
  (0x2fff0) -> `AdcScanStep` (0x23d8c): **spin until 60c001 bit 4 (EOC) = 1**,
  `move.b b00001 -> ff8000 + previous_channel`, next channel from the 16-entry
  table at 0x4a8ac (0,1,...,7,0,...,7), then three byte writes to **b80001**:
  `ch`, `ch|0x48`, `ch` (bit 3 = START, bit 6 = 12-bit latch, harmless).
  Joystick X = ff8000 (ch 0), Y = ff8002 (ch 2). `AdcStart` (0x23e06) writes
  0x48 then 0x00 before interrupts are enabled, so a conversion is always in
  flight. **RTL: EOC must read 1 whenever no conversion is running and go to 1
  within a few ms of START, otherwise the timer IRQ spins and the watchdog
  resets the machine.** The stage-1/self-test handler `Irq5Timer` (0x82c) also
  touches the 12-bit ADC (b80000 <- 0x80, reads b80001; unused, reads 0xfff).
- **Coins**: `CoinService` (0x20430), also from the timer tick. Reads
  `move.b 60c001,D2; bset #5,D2` (mask off self-test) and shifts bits 7, 6
  through the debouncer (`asl.b` + `bcs`): **coins are port 0 bits 7 (COIN1)
  and 6 (COIN2), active low**, plus a80001 bit 2 for start. The JSA response
  bytes are never used for coins (any unexpected byte resets the sound board,
  section 4). Coin counters: /WR0 latch `a0000c/a0000e` (sel 6/7 value 0) and
  `a0001c/a0001e` (value 1). Credits/options are kept in ZRAM (`ZramService`,
  0x2053c) with the ZP1/ZP2 sequence `clr.w 604008; clr.w 60401a; write byte;
  clr.w 604018; clr.w 60400a` under IRQ mask 7.
- **IRQ5 ack**: `clr.w 60c000` at the end of `GameIrq5Timer`; the tick counter
  is ff8014 (long), used for frame timing (ffdb36/ff9baa) but not for pacing.

---

## 6. VBLANK and the display interrupt

The game code never polls VBLANK; frame pacing is entirely
**IRQ3 = GSP INTOUT** (`GameIrq3Gsp` 0x2143c: `ffdb48 = 0xffff`,
`andi.w #0xff7f,c00008`, records ff8014-ffdb36 into ff9baa) combined with
**IRQ2 = ADSP done**. `GspWaitIrq3` and the ADSP wait in `FrameUpdate` are the
only frame waits. The GSP program itself uses the 34010 display interrupt
(DPYINT) to raise INTOUT once per frame after the command buffer is drawn; the
68k sees exactly one IRQ3 per consumed buffer. The stage-1 handler `Irq3Gsp`
(0x7d6) does the same (ff9046 = -1) for the self-test.

---

## 7. DUART (MC68681, ff0000-ff001f, registers on the **even** byte = D15:8)

Game code touches: SRA ff0002 (r), CRA ff0004 (w: 0x20 reset RX, 0x01 enable
RX, 0x40 reset error), RHRA/THRA ff0006, IMR ff000a (w, shadow ff904a), SRB
ff0012 (r), CRB ff0014 (w), RHRB/THRB ff0016, OPR-set ff001c (w 0x20) and
OPR-reset ff001e (w 0x20). All of these are in `DuartRxTxIrqHandler` (0x239fe,
IRQ6) and its helpers 0x23a54/0x23aa0/0x23b0a/0x23b54/`DuartSendB` (0x23d4e,
unreferenced). **No MR1/MR2, CSR, ACR, IVR or IMR write happens on the game
boot path**, so a 68681 stays in its reset state (IMR = 0) and never asserts
IRQ6. A missing DUART cannot hang the boot: nothing waits on it unless SW1 bit
14/12 selects serial download (then `GspLoadFromSerial`/`AdspLoadFromSerial`
spin on 0x23c9a forever). The self-test's DUART test (0xf130/0xf1ee/0xf26c,
0x9bb0 reads ff0000) is the only other user. RTL: return 0xffff (or anything)
for ff0000-ff001f and keep IRQ6 deasserted.

---

## 8. Error paths (GSP / ADSP failure)

Error string table at **0x4a954** (`ErrorDisplay` indexes `[0x4a954 + 4*code]`,
code clamped to 0x10):

| code | string | raised by |
|---|---|---|
| 1 | BUSS ERROR | vector 2 -> `GameBusError` (0x22954) -> 0x30676 |
| 2 | ADDRESS ERROR | 0x229b4 |
| 3 | ILLEGAL INST ERROR | 0x229a4 |
| 5 | CHK INST ERROR | 0x22984 |
| 6 | TRAP ERROR | |
| 8 | GSP HANDSHAKE ERROR | `GspFrameBegin`: flag word still non-zero after IRQ3 |
| 9 | BAD POLY BUFF ERROR | |
| 0xa | MSP TIME OUT ERROR | (no MSP) |
| 0xb | ADSP TIME OUT ERROR | `FrameUpdate`: 100000 loops without IRQ2/ff9bb4 |
| 0xc | GSP TIME OUT ERROR | `GspWaitIrq3`: 0x80000 loops without IRQ3, banner "OUT OF SYNC" or "END GSP BUFFER" |
| 0xd | GENERIC ERROR | |
| 0xe | NMI ERROR | `GameIrq7` (0x229c4) |
| 0xf | SPUR EXPTN ERROR | `GameSpuriousIrq` (0x229d4): spurious, L1, trace, line A/F, traps |
| 0x10 | ILLEGAL ERROR CODE | |

`FatalError(code)` (0x30830) / `TimeoutFatalWithBanner(code, msg)` (0x308c4):
SR = 0x2700, `GspResetAndInit` (the GSP is reset and re-initialised so the
68k can draw), clear screen, font load, prints a row of 0x5c at (0,0xd0), the
error string at (0x20,0xd0) (and the banner at (0x20,0x80)), increments the
error counter for that code in EEPROM (ff4b90 + code) under ZP1/ZP2, then
kicks the watchdog **0x100000 times** (keeps the message on screen for a few
seconds) and finally `HaltForWatchdog` = `stop #0x2700` with no more kicks ->
watchdog reset -> `reset_entry` -> the whole boot repeats (the EEPROM error
counts are what the self-test's "ERROR COUNTS" page shows). Other silent
failures that go straight to `HaltForWatchdog`: bad GSP image remainder,
object list overflow (> 0x15e3 words), SOM buffer without 0xffff terminator.

Self-test path (bit 5 = 0): `SelfTestEntry` (0x8fee) -> `SelfTestGspInit`
(0x53f2: same NWR reset pulse, HSTCTL = 0xb800, video registers, DPYSTRT =
0xffff, PSIZE = 8, DPYCTL = 0xf010, LED) -> 0x548e/0x54c2 (VRAM zero fill,
expander clear) -> menu at 0x900a driven by SW1. The stage-1 vector table at 0
is in force there (`Irq5Timer` 0x82c scans the ADC, `Irq4Sound` 0x81c drains
600000, `Irq3Gsp` 0x7d6 sets ff9046).

---

## 9. Vector tables

| vec | ROM table at 0 (stage 1 / self-test) | game table at 0x20000 (VBR) |
|---|---|---|
| 0/1 | SSP ffffc000, PC 000216 | SSP 00000000, PC 0212ae `GameInit` |
| 2 bus | 01076a | 022954 `GameBusError` |
| 3 addr | 01078e | 0229b4 |
| 4 illegal | 0107b0 | 0229a4 |
| 5 zero div | 0107c2 | 022994 |
| 6 chk | 0107d4 | 022984 |
| 7 trapv | 0107e2 | 022964 |
| 8 priv | 0107f0 | 022974 |
| 9-11 | 0107fe / 000212 / 000212 | 0229d4 `GameSpuriousIrq` |
| 24 spurious | 01082c | 0229d4 |
| 25 L1 (MSP) | 0007fa | 0229d4 |
| 26 L2 ADSP | 0007f0 `Irq2Adsp` (rte only) | 0213fe `GameIrq2Adsp` |
| 27 L3 GSP | 0007d6 `Irq3Gsp` | 02143c `GameIrq3Gsp` |
| 28 L4 sound | 00081c `Irq4Sound` | 023f24 (`SoundResponseIrqHandler` body) |
| 29 L5 timer | 00082c `Irq5Timer` | 0222da `GameIrq5Timer` |
| 30 L6 DUART | 000812 `Irq6Duart` (rte only) | 0239fe `DuartRxTxIrqHandler` |
| 31 L7 | 01082c | 0229c4 `GameIrq7` |
| 32+ traps | 010848 | 0229d4 |

---

## 10. Checklist for the RTL trace

1. After reset: reads of 604000 and 600000, writes 608000/60c000/818060,
   and harmless writes to 840000/84c000/818040/c04002-c0400c.
2. NWR: 60400c then 60401c (GSP reset pulse) - twice on the game path (stage 1
   and `GspResetAndInit`), then 604010 every frame (CR2), 604008/60401a/
   604018/60400a around ZRAM writes, 604012 (LC1) in the self-test.
3. HSTCTL sequence a000, b800 (via HSTDATA to c0000100 as well), |1800,
   b800, 7800, 3800; then only &ff7f (IRQ3) and &e7ff/restore (text).
4. 12184 HSTDATA words to fff40000.. (GSP program) with INCW; after HLT
   release the GSP must clear the VRAM flag at fff9fc00/fffcfc00 and pulse
   INTOUT once per frame.
5. 2728 longs to 800000-80226b/8040a4-8048d7 (ADSP program) between /BR=0,
   HALT=0, RESET=0 and RESET=1; then the 11-write release sequence ending with
   81801c.
6. Per frame: IRQ2 -> 818060, BR halt/release, read 80bfc6; 818006/818016
   alternate; data words 0x1fe4-0x1fff rewritten; 810000 read back with
   `count, ..., 0xffff`.
7. Sound: 0xff after reset, bits2:0 = 0 in reply to 0x07; a80000 bit 15 = 1.
8. ADC: EOC (port 0 bit 4) = 1 when idle; conversions started by byte writes
   to b80001 with bit 3.
