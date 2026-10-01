#!/usr/bin/env python3
"""rv32i-cpu -- generate the block diagram and the pipeline timing diagram.

Run with any Python 3 that has Pillow:

    python3 tools/make_figures.py            # writes docs/figures/*.png

Two figures are produced:

  pipeline-block-diagram.png  the five stages, the pipeline registers, both
                              memories, the forwarding network, the hazard unit
                              and the trap logic
  pipeline-timing.png         cycle by cycle occupancy showing the pipeline
                              fill, a load-use stall and a taken-branch flush
"""

import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow is required: run with a Python that has PIL installed")
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "docs", "figures")

FONTS = [
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Verdana.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]

BG = (255, 255, 255)
INK = (28, 32, 38)
GREY = (110, 118, 128)
LINE = (60, 66, 74)

STAGE_FILL = {
    "IF": (222, 236, 252),
    "ID": (226, 245, 226),
    "EX": (255, 240, 214),
    "MEM": (243, 228, 248),
    "WB": (255, 228, 228),
}
REG_FILL = (246, 247, 249)
MEM_FILL = (236, 240, 244)
CTRL_FILL = (255, 249, 219)


def font(size, bold=False):
    for path in FONTS:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


F_TITLE = font(26, True)
F_BOX = font(17, True)
F_LBL = font(13)
F_SMALL = font(11)


def box(d, xy, fill, outline=LINE, radius=8, width=2):
    d.rounded_rectangle(xy, radius=radius, fill=fill, outline=outline, width=width)


def text(d, xy, s, f, fill=INK, anchor="mm"):
    d.text(xy, s, font=f, fill=fill, anchor=anchor)


def arrow(d, p0, p1, color=LINE, width=2, head=9, dash=None):
    x0, y0 = p0
    x1, y1 = p1
    if dash:
        # simple dashed line along the dominant axis
        if y0 == y1:
            step = dash * 2
            x = x0
            while x < x1:
                d.line([(x, y0), (min(x + dash, x1), y0)], fill=color, width=width)
                x += step
        else:
            step = dash * 2
            y = y0
            while y < y1:
                d.line([(x0, y), (x0, min(y + dash, y1))], fill=color, width=width)
                y += step
    else:
        d.line([p0, p1], fill=color, width=width)
    # arrow head
    if abs(x1 - x0) >= abs(y1 - y0):
        s = 1 if x1 > x0 else -1
        d.polygon([(x1, y1), (x1 - s * head, y1 - head // 2),
                   (x1 - s * head, y1 + head // 2)], fill=color)
    else:
        s = 1 if y1 > y0 else -1
        d.polygon([(x1, y1), (x1 - head // 2, y1 - s * head),
                   (x1 + head // 2, y1 - s * head)], fill=color)


# ===========================================================================
# figure 1: block diagram
# ===========================================================================
def block_diagram():
    W, H = 1400, 880
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    text(d, (30, 30), "rv32i-cpu  --  five stage in-order RV32I pipeline",
         F_TITLE, INK, anchor="lm")
    text(d, (30, 60),
         "Verilog-2001/2005  |  static predict-not-taken  |  EX resolves every control transfer  |  commit point at EX->MEM",
         F_SMALL, GREY, anchor="lm")

    # ---- geometry --------------------------------------------------------
    SY, SH = 240, 100                       # stage row
    stage_x = {"IF": 300, "ID": 510, "EX": 720, "MEM": 930, "WB": 1140}
    BW = 150
    reg_x = {}                              # pipeline register left edges
    reg_names = ["IF/ID", "ID/EX", "EX/MEM", "MEM/WB"]
    keys = ["IF", "ID", "EX", "MEM"]
    for k, nm in zip(keys, reg_names):
        reg_x[k] = stage_x[k] + BW + 8

    # ---- PC and instruction memory --------------------------------------
    box(d, (60, 110, 220, 175), (232, 236, 242), width=3)
    text(d, (140, 133), "PC", F_BOX)
    text(d, (140, 156), "RESET_PC", F_SMALL, GREY)

    box(d, (280, 110, 470, 175), MEM_FILL, width=3)
    text(d, (375, 133), "I-Mem  64 KiB", F_BOX)
    text(d, (375, 156), "combinational read", F_SMALL, GREY)

    arrow(d, (222, 142), (278, 142))                       # PC -> I-Mem
    text(d, (250, 128), "addr", F_SMALL, GREY)
    arrow(d, (375, 177), (375, SY - 2))                    # I-Mem -> IF
    text(d, (455, 205), "instr", F_SMALL, GREY)

    box(d, (60, SY, 220, SY + 70), CTRL_FILL, width=3)     # next-PC select
    text(d, (140, SY + 22), "next-PC select", F_BOX)
    text(d, (140, SY + 48), "pc+4 | target | hold", F_SMALL, GREY)
    arrow(d, (140, SY - 2), (140, 177))                    # -> PC
    arrow(d, (250, SY + 35), (stage_x["IF"] - 2, SY + 35)) # -> IF

    # ---- stages ----------------------------------------------------------
    subs = {"IF": "fetch", "ID": "decode / regfile", "EX": "execute / branch",
            "MEM": "memory access", "WB": "write back"}
    for lb, x in stage_x.items():
        box(d, (x, SY, x + BW, SY + SH), STAGE_FILL[lb], width=3)
        text(d, (x + BW // 2, SY + 38), lb, F_BOX)
        text(d, (x + BW // 2, SY + 66), subs[lb], F_SMALL, GREY)

    for k, nm in zip(keys, reg_names):
        x = reg_x[k]
        box(d, (x, SY - 30, x + 42, SY + SH + 30), REG_FILL, radius=6)
        tmp = Image.new("RGBA", (120, 26), (0, 0, 0, 0))
        td = ImageDraw.Draw(tmp)
        td.text((60, 13), nm, font=F_LBL, fill=INK, anchor="mm")
        tmp = tmp.rotate(90, expand=True)
        img.paste(tmp, (x + 21 - 13, SY + SH // 2 - 60), tmp)

    # ---- data memory -----------------------------------------------------
    box(d, (940, 420, 1075, 520), MEM_FILL, width=3)
    text(d, (1007, 448), "D-Mem", F_BOX)
    text(d, (1007, 472), "byte enables", F_SMALL, GREY)
    text(d, (1007, 492), "comb read", F_SMALL, GREY)
    arrow(d, (985, SY + SH + 2), (985, 418))
    arrow(d, (1030, 418), (1030, SY + SH + 2))
    text(d, (890, 380), "addr/wdata/wstrb", F_SMALL, GREY)

    # ---- forwarding unit -------------------------------------------------
    box(d, (700, 400, 900, 480), CTRL_FILL, width=3)
    text(d, (800, 420), "forwarding", F_BOX)
    text(d, (800, 444), "EX/MEM -> EX  (H1)", F_SMALL, GREY)
    text(d, (800, 462), "MEM/WB -> EX  (H2)", F_SMALL, GREY)
    arrow(d, (899, SY + SH + 32), (899, 398))               # EX/MEM -> fwd
    d.line([(1109, SY + SH + 32), (1109, 385)], fill=(196, 92, 60), width=2)
    d.line([(1109, 385), (860, 385)], fill=(196, 92, 60), width=2)
    arrow(d, (860, 385), (860, 398), color=(196, 92, 60))   # MEM/WB -> fwd
    arrow(d, (760, 398), (760, SY + SH + 2))                # fwd -> EX
    text(d, (620, 372), "operands", F_SMALL, GREY)

    # ---- hazard unit -----------------------------------------------------
    box(d, (300, 400, 660, 480), CTRL_FILL, width=3)
    text(d, (480, 420), "hazard unit   rv32i_hazard", F_BOX)
    text(d, (480, 444), "H4 load-use stall  |  forward selects  |  H3 in regfile",
         F_SMALL, GREY)
    arrow(d, (480, 398), (480, SY + SH + 2))                # -> IF/ID
    text(d, (500, 372), "hold / bubble", F_SMALL, (60, 120, 196))
    d.line([(300, 440), (240, 440)], fill=(60, 120, 196), width=2)
    d.line([(240, 440), (240, SY + 22)], fill=(60, 120, 196), width=2)
    arrow(d, (240, SY + 22), (222, SY + 22), color=(60, 120, 196))
    text(d, (250, 500), "stall", F_SMALL, (60, 120, 196))

    # ---- redirect / flush ------------------------------------------------
    box(d, (300, 540, 760, 620), CTRL_FILL, width=3)
    text(d, (530, 562), "redirect / flush", F_BOX)
    text(d, (530, 588), "taken branch or jump: flush IF/ID + ID/EX, PC <- target (2 cycles)",
         F_SMALL, GREY)
    d.line([(300, 580), (262, 580)], fill=(60, 120, 196), width=2)
    d.line([(262, 580), (262, SY + 48)], fill=(60, 120, 196), width=2)
    arrow(d, (262, SY + 48), (222, SY + 48), color=(60, 120, 196))
    text(d, (272, 640), "actual_taken / target", F_SMALL, (60, 120, 196))

    # ---- trap / halt -----------------------------------------------------
    box(d, (300, 670, 900, 750), (255, 232, 232), width=3)
    text(d, (600, 692), "trap / halt logic   (EX stage)", F_BOX)
    text(d, (600, 718),
         "illegal(2) | ebreak(3) | misaligned(0/4/6) | ecall(11)  ->  precise, fail-stop",
         F_SMALL, GREY)
    text(d, (600, 738),
         "squashes every younger instruction, lets older ones commit, then stops fetching",
         F_SMALL, GREY)

    # ---- retire port -----------------------------------------------------
    text(d, (930, 690), "retire_valid_o / retire_pc_o / retire_instr_o",
         F_SMALL, (196, 92, 60))
    text(d, (930, 708), "(commit point, EX->MEM)", F_SMALL, (196, 92, 60))

    # ---- legend ----------------------------------------------------------
    ly = H - 46
    text(d, (30, ly), "legend:", F_SMALL, GREY, anchor="lm")
    items = [("pipeline stage", STAGE_FILL["EX"]), ("pipeline register", REG_FILL),
             ("memory", MEM_FILL), ("control / hazard", CTRL_FILL)]
    x = 100
    for nm, col in items:
        box(d, (x, ly - 9, x + 24, ly + 9), col, width=2)
        text(d, (x + 30, ly), nm, F_SMALL, GREY, anchor="lm")
        x += 160
    d.line([(x, ly), (x + 60, ly)], fill=(196, 92, 60), width=2)
    text(d, (x + 66, ly), "data / select", F_SMALL, GREY, anchor="lm")
    x += 190
    d.line([(x, ly), (x + 60, ly)], fill=(60, 120, 196), width=2)
    text(d, (x + 66, ly), "stall / flush", F_SMALL, GREY, anchor="lm")

    img.save(os.path.join(OUT, "pipeline-block-diagram.png"))
    print("wrote docs/figures/pipeline-block-diagram.png")


# ===========================================================================
# figure 2: pipeline timing
# ===========================================================================
def timing_diagram():
    cycles = 12
    cell_w, cell_h = 92, 44
    left, top = 200, 150
    rows = 10
    W = left + cycles * cell_w + 30
    H = top + rows * cell_h + 190

    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    text(d, (30, 30), "Pipeline timing: fill, load-use stall, taken-branch flush",
         F_TITLE, INK, anchor="lm")
    text(d, (30, 62),
         "I0 = lw x5,0(x6)    I1 = add x7,x5,x8 (uses x5)    I2 = beq (taken)    T = branch target",
         F_LBL, GREY, anchor="lm")

    for c in range(cycles):
        text(d, (left + c * cell_w + cell_w // 2, top - 22), "cyc %d" % (c + 1),
             F_SMALL, GREY)

    FI, DI, EI, MI, WI = (STAGE_FILL["IF"], STAGE_FILL["ID"], STAGE_FILL["EX"],
                          STAGE_FILL["MEM"], STAGE_FILL["WB"])
    BUB = (240, 240, 240)
    BAD = (250, 214, 214)

    row_names = ["IF", "ID", "EX", "MEM", "WB", "", "I0  lw", "I1  add", "I2  beq", "T   target"]
    for r, nm in enumerate(row_names):
        y = top + r * cell_h
        if not nm:
            continue
        fill = STAGE_FILL.get(nm, (240, 244, 248) if r < 6 else (232, 238, 246))
        box(d, (30, y + 4, 30 + 150, y + cell_h - 4), fill, radius=6)
        text(d, (105, y + cell_h // 2), (nm + " stage") if r < 5 else nm, F_LBL)

    for r in range(rows + 1):
        y = top + r * cell_h
        d.line([(left, y), (left + cycles * cell_w, y)], fill=(228, 231, 235))
    for c in range(cycles + 1):
        x = left + c * cell_w
        d.line([(x, top), (x, top + rows * cell_h)], fill=(228, 231, 235))

    def cell(row, col, label, color, sub=None, small=True):
        x = left + col * cell_w
        y = top + row * cell_h
        box(d, (x + 3, y + 3, x + cell_w - 3, y + cell_h - 3), color, radius=5, width=2)
        f = F_SMALL if small else F_LBL
        if sub:
            text(d, (x + cell_w // 2, y + cell_h // 2 - 7), label, f)
            text(d, (x + cell_w // 2, y + cell_h // 2 + 8), sub, F_SMALL, GREY)
        else:
            text(d, (x + cell_w // 2, y + cell_h // 2), label, f)

    # ---- stage occupancy -------------------------------------------------
    #  c1     c2     c3     c4          c5     c6            c7      c8
    cell(0, 0, "I0", FI); cell(0, 1, "I1", FI); cell(0, 2, "I2", FI)
    cell(0, 3, "I2", FI, sub="hold")
    cell(0, 4, "I3", FI)
    cell(0, 5, "I4", BAD, sub="squash")
    cell(0, 6, "T", FI); cell(0, 7, "T+1", FI); cell(0, 8, "T+2", FI)

    cell(1, 1, "I0", DI); cell(1, 2, "I1", DI)
    cell(1, 3, "I1", (255, 236, 204), sub="stall")
    cell(1, 4, "I2", DI)
    cell(1, 5, "I3", BAD, sub="squash")
    cell(1, 6, "bubble", BUB)
    cell(1, 7, "T", DI); cell(1, 8, "T+1", DI)

    cell(2, 2, "I0", EI)
    cell(2, 3, "bubble", BUB, sub="H4")
    cell(2, 4, "I1", EI, sub="H2")
    cell(2, 5, "I2", (255, 214, 214), sub="taken")
    cell(2, 6, "bubble", BUB); cell(2, 7, "bubble", BUB)
    cell(2, 8, "T", EI); cell(2, 9, "T+1", EI)

    cell(3, 3, "I0", MI); cell(3, 4, "I1", MI); cell(3, 5, "I2", MI)
    cell(3, 6, "bubble", BUB); cell(3, 7, "bubble", BUB); cell(3, 8, "bubble", BUB)
    cell(3, 9, "T", MI)

    cell(4, 4, "I0", WI); cell(4, 5, "I1", WI); cell(4, 6, "I2", WI)
    cell(4, 7, "bubble", BUB); cell(4, 8, "bubble", BUB); cell(4, 9, "bubble", BUB)
    cell(4, 10, "T", WI)

    # ---- instruction rows ------------------------------------------------
    cell(6, 0, "IF", FI); cell(6, 1, "ID", DI); cell(6, 2, "EX", EI)
    cell(6, 3, "MEM", MI); cell(6, 4, "WB", WI)

    cell(7, 1, "IF", FI); cell(7, 2, "ID", DI)
    cell(7, 3, "ID", (255, 236, 204), sub="stall")
    cell(7, 4, "EX", EI, sub="H2"); cell(7, 5, "MEM", MI); cell(7, 6, "WB", WI)

    cell(8, 2, "IF", FI); cell(8, 3, "IF", FI, sub="hold"); cell(8, 4, "ID", DI)
    cell(8, 5, "EX", (255, 214, 214), sub="taken")
    cell(8, 6, "MEM", MI); cell(8, 7, "WB", WI)

    cell(9, 6, "IF", FI); cell(9, 7, "ID", DI); cell(9, 8, "EX", EI)
    cell(9, 9, "MEM", MI); cell(9, 10, "WB", WI)

    # ---- annotations -----------------------------------------------------
    y = top + rows * cell_h + 34
    text(d, (30, y),
         "11 cycles for 4 retired instructions: 3 bubble cycles = 1 load-use stall + 2 branch flush",
         F_LBL, INK, anchor="lm")
    text(d, (30, y + 24),
         "cyc 3: I0 (the load) is in EX while I1 needs x5 in ID  ->  the interlock holds I1 one cycle and "
         "injects a bubble into EX",
         F_SMALL, GREY, anchor="lm")
    text(d, (30, y + 44),
         "cyc 4: I0 reaches WB, I1 enters EX and takes x5 on the MEM/WB forwarding path (H2) - no second stall",
         F_SMALL, GREY, anchor="lm")
    text(d, (30, y + 64),
         "cyc 6: I2 (the branch) resolves in EX and is taken  ->  PC redirects, the two younger instructions "
         "are squashed, EX gets bubbles in cyc 7 and 8",
         F_SMALL, GREY, anchor="lm")
    text(d, (30, y + 84),
         "cyc 9: the target reaches EX, i.e. two cycles later than it would have without the branch",
         F_SMALL, GREY, anchor="lm")

    img.save(os.path.join(OUT, "pipeline-timing.png"))
    print("wrote docs/figures/pipeline-timing.png")


def main():
    os.makedirs(OUT, exist_ok=True)
    block_diagram()
    timing_diagram()
    return 0


if __name__ == "__main__":
    sys.exit(main())
