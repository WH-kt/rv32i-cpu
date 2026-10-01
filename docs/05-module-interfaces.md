# 05 — 模块划分与接口定义（Phase 5）

> 语言：**Verilog-2001/2005**。所有端口为 ANSI 风格，位宽显式，方向明确。
> 本文档定义的端口即为**冻结接口**；任何变更必须同步更新本文档与 `03`。

---

## 1. 层次结构

```
rv32i_soc                        (rtl/soc/rv32i_soc.v)     仿真/FPGA 顶层：内核 + 双口存储器 + MMIO
├── u_cpu     : rv32i_cpu        (rtl/core/rv32i_cpu.v)    五级流水线内核（唯一有状态的复杂模块）
│   ├── u_regfile : rv32i_regfile(rtl/regfile/rv32i_regfile.v)
│   ├── u_decoder : rv32i_decoder(rtl/control/rv32i_decoder.v)
│   ├── u_immgen  : rv32i_immgen (rtl/control/rv32i_immgen.v)
│   ├── u_hazard  : rv32i_hazard (rtl/control/rv32i_hazard.v)
│   ├── u_alu     : rv32i_alu    (rtl/alu/rv32i_alu.v)
│   └── u_brcmp   : rv32i_brcmp  (rtl/alu/rv32i_brcmp.v)
├── u_imem    : rv32i_ram        (rtl/memory/rv32i_ram.v)  指令存储器（组合读，只写由 INIT_FILE 完成）
└── u_dmem    : rv32i_ram        (rtl/memory/rv32i_ram.v)  数据存储器（组合读 + 字节使能写）
```

共享头文件：`rtl/include/rv32i_defs.vh`（`` `define `` 常量，`ifndef` 保护）。
**除 `rv32i_cpu` 外，任何模块不得例化其它模块**（`rv32i_soc` 只例化内核与存储器）。

---

## 2. 模块接口

### 2.1 `rv32i_alu` — 组合 ALU

```verilog
module rv32i_alu (
    input  wire [3:0]  alu_op,   // `ALU_* 编码（见 03 §4）
    input  wire [31:0] a,        // 操作数 A（已前递）
    input  wire [31:0] b,        // 操作数 B（已前递）
    output reg  [31:0] y         // 结果
);
```
- 纯组合，无状态，无时钟。全部操作在 32 位模 2³² 下定义。
- `PASS_B` 用于 LUI；移位量取 `b[4:0]`；`SRA/SLT` 使用 `$signed`。

### 2.2 `rv32i_brcmp` — 分支条件比较器

```verilog
module rv32i_brcmp (
    input  wire [2:0]  br_op,    // 分支 funct3: 0,1,4,5,6,7
    input  wire [31:0] a,        // 已前递的 rs1
    input  wire [31:0] b,        // 已前递的 rs2
    output reg         taken     // 条件成立
);
```
- 与 ALU 共享同一组前递后的操作数；未定义 `br_op`（2、3）输出 0（并由译码器保证非法编码不会到达）。

### 2.3 `rv32i_regfile` — 寄存器堆（2 读 1 写 + 写穿透）

```verilog
module rv32i_regfile #(
    parameter RF_INIT_EN = 1     // 1: 复位清零（确定性）；0: 省面积
)(
    input  wire        clk,
    input  wire        reset,
    input  wire        we,       // 写使能（来自 MEM/WB）
    input  wire [4:0]  waddr,
    input  wire [31:0] wdata,
    input  wire [4:0]  raddr1,
    input  wire [4:0]  raddr2,
    output wire [31:0] rdata1,   // 组合读 + 写穿透（冒险 H3）
    output wire [31:0] rdata2
);
```
- `x0` 恒 0：写被忽略，读恒 0。
- **写穿透**：`rdata = (we & waddr!=0 & waddr==raddr) ? wdata : rf[raddr]`（冒险 H3）。

### 2.4 `rv32i_decoder` — 主译码器

```verilog
module rv32i_decoder (
    input  wire [31:0] instr,
    output reg  [`CTRL_W-1:0] ctrl, // 打包控制字（见 03 §3）；非法编码时为 0 且 illegal=1
    output wire [4:0]  rs1_addr,   // instr[19:15]
    output wire [4:0]  rs2_addr,   // instr[24:20]
    output wire [4:0]  rd_addr,    // instr[11:7]
    output wire        uses_rs1,   // 真实读取 rs1（决定 H4 停顿与 H1/H2 相关性）
    output wire        uses_rs2
);
```
- 纯组合；`default` 分支置 `CTRL_ILLEGAL=1`、其余字段 0（保证无锁存、无未定义控制）。

### 2.5 `rv32i_immgen` — 立即数生成器

```verilog
module rv32i_immgen (
    input  wire [31:0] instr,
    output reg  [31:0] imm        // 已符号扩展/已对齐的 32 位立即数
);
```
- 按 `instr[6:0]` 选择 I/S/B/U/J 五种格式（见 03 §5）；非立即数类指令输出 0。

### 2.6 `rv32i_hazard` — 冒险检测 / 前递选择

```verilog
module rv32i_hazard (
    // 消费者：ID 级（Load-Use 判定）—— IF/ID 寄存器
    input  wire        if_id_valid,
    input  wire        id_ex_valid,
    input  wire        id_ex_mem_re,
    input  wire [4:0]  id_ex_rd_addr,
    input  wire [4:0]  id_ex_rs1_addr,   // 仅用于前递选择
    input  wire [4:0]  id_ex_rs2_addr,
    // 生产者：MEM 级 —— EX/MEM 寄存器
    input  wire        ex_mem_valid,
    input  wire        ex_mem_rf_we,
    input  wire        ex_mem_mem_re,
    input  wire [4:0]  ex_mem_rd_addr,
    // 生产者：WB 级 —— MEM/WB 寄存器
    input  wire        mem_wb_valid,
    input  wire        mem_wb_rf_we,
    input  wire [4:0]  mem_wb_rd_addr,
    input  wire        if_id_uses_rs1,
    input  wire        if_id_uses_rs2,
    input  wire [4:0]  if_id_rs1_addr,
    input  wire [4:0]  if_id_rs2_addr,
    // 输出
    output reg  [1:0]  fwd_a_sel,   // 2'b00=寄存器堆, 2'b01=MEM/WB(H2), 2'b10=EX/MEM(H1)
    output reg  [1:0]  fwd_b_sel,
    output reg         stall        // H4：停顿 1 拍
);
```
- 纯组合。`stall` 只依赖 `id_ex_*` 与 `if_id_*`（Load-Use，且被 `if_id_valid` 门控）；
  `fwd_*` 只依赖 `id_ex_rs*_addr` 与 `ex_mem_*`/`mem_wb_*`。
- 返回 `fwd_*_sel` 与 `stall` 的直接原因由 `tb_hazard` 逐条穷举验证。

### 2.7 `rv32i_cpu` — 五级流水线内核（顶层）

```verilog
module rv32i_cpu #(
    parameter RESET_PC = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        reset,
    // 指令接口
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    // 数据接口
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    output wire        dmem_we,
    output wire        dmem_re,
    input  wire [31:0] dmem_rdata,
    // 系统停机请求
    input  wire        halt_i,
    // 陷阱观测
    output wire        trap_o,
    output wire [3:0]  trap_cause_o,
    output wire [31:0] trap_pc_o,
    // 退休观测（EX→MEM 提交点）
    output wire        retire_valid_o,
    output wire [31:0] retire_pc_o,
    output wire [31:0] retire_instr_o
);
```

**时序语义**：
| 信号 | 语义 |
|---|---|
| `imem_addr` | 组合输出，恒 4 字节对齐；`imem_rdata` 必须**同拍**有效 |
| `dmem_*` | 组合输出，仅在 MEM 级有效；`dmem_we` 高时上升沿写入 |
| `dmem_rdata` | 必须**同拍**有效（对齐字） |
| `halt_i` | 电平；拉高后内核抹除 MEM 之后的年轻指令并冻结取指（粘滞到 `reset`） |
| `trap_o` | 电平；陷阱后保持到 `reset`；同时内核停止取指 |
| `retire_*_o` | 每提交一条指令拉高 1 拍；触发陷阱的指令**不**产生脉冲 |

### 2.8 `rv32i_ram` — 通用 RAM（组合读 + 字节使能写）

```verilog
module rv32i_ram #(
    parameter MEM_WORDS = 16384,   // 字数（16384 = 64 KiB）
    parameter INIT_FILE = ""       // 非空则 $readmemh 初始化
)(
    input  wire        clk,
    input  wire [31:0] addr,       // 字节地址（内部按 addr[31:2] 索引）
    input  wire        we,
    input  wire [3:0]  wstrb,
    input  wire [31:0] wdata,
    output wire [31:0] rdata       // 组合读
);
```
- 唯一的 `initial` 块：先以 `FILL` 填满，再 `$readmemh`（FPGA BRAM 初始化标准做法）；
  RTL 其余部分无 `initial`。指令存储器填 `0x0000_0013`（NOP），数据存储器填 0，
  因此仿真中不会出现 X 值，也不会出现未定义取指。
- 越界地址：读 0，写忽略（确定性），由模块内部的地址比较完成。

### 2.9 `rv32i_soc` — 系统顶层

```verilog
module rv32i_soc #(
    parameter MEM_WORDS = 16384,
    parameter INIT_FILE = "",
    parameter RESET_PC  = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        reset,
    // 测试平台观测
    output wire        halt_o,          // 停机（MMIO halt）
    output wire [7:0]  halt_code_o,
    output wire        trap_o,          // 体系结构陷阱
    output wire [3:0]  trap_cause_o,
    output wire [31:0] trap_pc_o,
    output wire [31:0] trap_tval_o,     // mtval 语义：非法指令=编码，非对齐=地址
    output wire        retire_valid_o,
    output wire [31:0] retire_pc_o,
    output wire [31:0] retire_instr_o,
    output wire [31:0] cycle_o,         // 已运行周期数
    // MMIO 事件（由 TB 格式化为与黄金模型一致的日志行）
    output wire        putc_valid_o,
    output wire [7:0]  putc_data_o,
    output wire        mark_valid_o,
    output wire [31:0] mark_data_o
);
```

**MMIO 映射**（与工作区既有黄金模型 `rvai/sw/iss.py` 完全一致，便于差分比对）：

| 地址 | 访问 | 行为 |
|---|---|---|
| `0x1000_0000` | W | putchar：`putc_valid_o=1, putc_data_o=wdata[7:0]` |
| `0x1000_0004` | W | halt：`halt_o=1, halt_code_o=wdata[7:0]`，并向内核拉高 `halt_i` |
| `0x1000_0008` | W | marker：`mark_valid_o=1, mark_data_o=wdata[31:0]` |
| `0x1000_000C` | R | 返回 `cycle_o`（真实周期数；黄金模型返回 0，故 benchmark 程序不参与差分） |
| 其它非 RAM 地址 | R/W | 读 0，写忽略 |

> MMIO 解码使用**完整字地址**（不做掩码），以保证 `sb` 打到 `0x1000_0001` 时不误触发事件。

---

## 3. 命名与编码规范（Phase 6 强制）

| 类别 | 规则 | 示例 |
|---|---|---|
| 级前缀 | `if_ / id_ / ex_ / mem_ / wb_` | `ex_alu_result` |
| 流水线寄存器 | `if_id_ / id_ex_ / ex_mem_ / mem_wb_` | `id_ex_ctrl` |
| 控制字位域 | `` `CTRL_* `` | `id_ex_ctrl[`CTRL_RF_WE]` |
| 常量 | 全大写 + `` `define `` | `` `ALU_ADD ``, `` `TRAP_ILLEGAL `` |
| 模块实例 | `u_<模块名>` | `u_alu` |
| 低有效信号 | 不使用（全部高有效），避免 `_n` 后缀歧义 | `reset`, `stall` |
| 复位 | 同步、高有效，统一 `if (reset) ... else ...` | — |
| 组合块 | `always @(*)` + 阻塞赋值；块首给全部被赋值信号默认值（防锁存） | — |
| 时序块 | `always @(posedge clk)` + 非阻塞赋值 | — |

---

## 4. 文件清单与规模估计

| 文件 | 内容 | 实际行数 |
|---|---|---|
| `rtl/include/rv32i_defs.vh` | 常量/位域/原因码 | 118 |
| `rtl/alu/rv32i_alu.v` | ALU | 36 |
| `rtl/alu/rv32i_brcmp.v` | 分支比较器 | 32 |
| `rtl/regfile/rv32i_regfile.v` | 寄存器堆 + 写穿透 | 55 |
| `rtl/control/rv32i_decoder.v` | 主译码器 | 262 |
| `rtl/control/rv32i_immgen.v` | 立即数生成 | 45 |
| `rtl/control/rv32i_hazard.v` | 前递 + 互锁 | 75 |
| `rtl/core/rv32i_cpu.v` | 五级流水线数据通路与控制 | 496 |
| `rtl/memory/rv32i_ram.v` | RAM | 65 |
| `rtl/soc/rv32i_soc.v` | SoC + MMIO | 142 |
| **RTL 合计** | | **1326** |
| `tb/` | SoC 级 TB + 8 个单元 TB | 1547 |
| `tools/` | 汇编器接口/ISS 比对/随机生成/覆盖率/FF 统计/lint | 1122 |
| `tb/programs/*.S` | 定向测试程序（23 个） | 约 1500 |

| 验证文件 | 内容 |
|---|---|
| `tb/tb_rv32i.v` | SoC 级自检 TB（日志、状态转储、超时、PASS/FAIL） |
| `tb/unit/tb_alu.v` `tb_brcmp.v` `tb_regfile.v` `tb_immgen.v` `tb_decoder.v` `tb_hazard.v` `tb_ram.v` `tb_reset.v` | 单元测试（每模块一个） |
| `tb/programs/*.S` | 定向汇编程序（见 `06` §4） |
| `tools/asm.py` `tools/iss.py` | 汇编器与黄金模型（Phase 7 从 `../rvai/sw` 引入或内置） |
| `tools/check_equiv.py` | 差分比对（寄存器堆 + 存储器 + 事件日志） |
| `tools/gen_random.py` | 约束随机程序生成器 |
| `Makefile` | 构建、仿真、差分、回归、lint 目标 |

---

## 5. 构建与仿真目标（Makefile 预览）

| 目标 | 作用 |
|---|---|
| `make lint` | `verilator --lint-only -Wall` + `iverilog -g2005 -Wall`（零警告） |
| `make unit` | 8 个单元 TB（自检 PASS/FAIL，失败返回非 0） |
| `make prog` | 先 `lint_asm.py` 检查立即数范围，再汇编到 `build/*.hex` |
| `make sim` | 逐程序跑 RTL，生成 `build/rtl_<name>.log/.state/.out` |
| `make iss` | 逐程序跑参考模型，生成 `build/iss_<name>.log` |
| `make diff` | `run_diff.py`：日志比对 + 自检判定 + 全状态比对 |
| `make random SEEDS=150` | 约束随机差分回归 |
| `make cov` | 指令覆盖率（取自 RTL retire 端口，要求 40/40） |
| `make wave P=smoke` | 用 GTKWave 打开指定程序的波形 |
| `make all` | `lint → unit → prog → sim → iss → diff → random → cov` |
| `make syn` | Yosys 综合/资源报告（未安装时给出明确提示） |
| `make vendor` | 把 `asm.py`/`iss.py` 复制进 `tools/vendor/`，使工程自包含 |

---

## 6. 接口稳定性

1. `rv32i_cpu` 的端口与 `rv32i_soc` 的 MMIO 映射冻结；变更需同步 `03/04/05/06` 四份文档。
2. 单元模块（ALU/比较器/立即数/译码器）端口只增不改语义。
3. 新增可选功能（如 `*_ready`、CSR）必须以**新增输入端口 + 默认行为不变**的方式引入。

下一份文档：`06-verification-plan.md`。
