# 01 — 需求分析（Phase 1）

> 项目：`rv32i-cpu` — 单核 RV32I 32 位处理器
> 状态：Phase 1 完成，等待架构评审
> 本文档只描述「必须满足什么」，不含微架构决策；微架构决策见 `02`、`03`。

---

## 1. 项目范围

| 项 | 内容 |
|---|---|
| 交付物 | 可综合 **Verilog** RTL + 自检式验证环境 + 设计/验证/综合报告 |
| RTL 语言 | **Verilog-2001/2005 可综合子集**（RTL/TB 全部 `.v`；不使用 SystemVerilog） |
| ISA | RISC-V RV32I Base Integer，**且仅限** RV32I |
| 核数 | 单核 |
| 顺序 | In-order、Single-issue（硬约束，架构自由度内不再放宽） |
| 目标 | 正确性 ≫ 可验证性 > 结构清晰 > 可实现性 > 性能 > 面积 > 功耗 |
| 运行形态 | 裸机（bare-metal），无 OS、无 MMU、无虚拟内存、无中断/异常返回 |

**明确不做**（不得自行假设其存在）：
M / A / F / D / C / Zicsr / Zifencei / Zicntr 扩展、特权模式（M/S/U）、CSR、
中断控制器、Cache、MMU/TLB、多核、原子操作、调试模块（JTAG/DM）、指令压缩。

> 判定规则：任何 RV32I 未定义的编码都必须被识别为**非法指令**，而不是当作 NOP 或
> 未定义行为执行（唯一例外见 §5.3 FENCE 的宽松处理，且已在文档中标注）。

---

## 2. 功能需求（ISA）

### 2.1 指令集合（RV32I 全集，共 40 条编码 + 2 条环境指令）

| 类别 | 指令 | 需求要点 |
|---|---|---|
| R-type | ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND | 移位量取 `rs2[4:0]`；SLT/SLTU 分别为有符号/无符号比较 |
| I-type ALU | ADDI, SLTI, SLTIU, XORI, ORI, ANDI | 12 位立即数**符号扩展**；SLTIU 的立即数先符号扩展再按无符号比较 |
| 移位立即数 | SLLI, SRLI, SRAI | 立即数同 RV32I 规范 |
| Load | LB, LH, LW, LBU, LHU | 地址 = rs1 + 符号扩展立即数；LB/LH 符号扩展，LBU/LHU 零扩展 |
| Store | SB, SH, SW | 地址同上；按字节写使能，未命中的字节保持不变 |
| Branch | BEQ, BNE, BLT, BGE, BLTU, BGEU | BLT/BGE 有符号，BLTU/BGEU 无符号；目标 = PC + B 立即数 |
| U-type | LUI, AUIPC | 立即数写入高 20 位，低 12 位清零；AUIPC 以**该指令自身 PC** 为基 |
| J-type | JAL | 目标 = PC + J 立即数；链接值 = PC + 4 |
| I-type 跳转 | JALR | 目标 = (rs1 + 符号扩展立即数) & ~1；链接值 = PC + 4 |
| 环境 | ECALL, EBREAK | 必须能被识别为环境调用/断点（本项目采用 §5 的 fail-stop 模型） |
| 内存序 | FENCE | 单核、无 Cache、无乱序，FENCE 退化为 NOP（见 §5.3） |

### 2.2 架构状态（Architectural State）

| 状态 | 宽度 | 复位值 | 说明 |
|---|---|---|---|
| PC | 32 | `RESET_PC` 参数（默认 `0x0000_0000`） | 复位后取指地址确定 |
| x0–x31 | 32×32 | **全 0**（`RF_INIT_EN=1` 时复位清零，见 §5.4） | x0 恒为 0，写入被丢弃 |
| 内存 | — | 由仿真/综合时的镜像初始化 | 唯一的外部状态 |

无其它隐藏状态：所有流水线寄存器在复位时被显式清为「气泡」（`valid=0`）。

### 2.3 必须成立的 ISA 不变量（后续验证直接挂钩）

- **R-x0**：`x0` 恒读 0；以 x0 为目的地的写不产生任何副作用（含前递路径）。
- **R-align-1**：指令地址必须 4 字节对齐（无 C 扩展）。
- **R-pc4**：JAL/JALR 的链接值恒为 `PC_of_jump + 4`。
- **R-imm**：B/J 立即数的 bit0 恒为 0；U 型立即数低 12 位恒为 0。
- **R-byte**：字节/半字访问只影响目标字节/半字，其它字节保持不变。
- **R-det**：同一程序、同一初始镜像、同一复位 → 完全相同的执行轨迹（确定性）。
- **R-x0init**：复位后所有体系结构可见状态确定为 0 / `RESET_PC`。

---

## 3. 接口需求

外部接口分为三组，全部**同步于单时钟域 `clk`**，复位 `reset` 为**同步、高有效**。

### 3.1 时钟与复位

| 信号 | 方向 | 宽度 | 说明 |
|---|---|---|---|
| `clk` | in | 1 | 单时钟域，所有状态在上升沿更新 |
| `reset` | in | 1 | 同步高有效；必须至少保持 1 个完整时钟周期 |

### 3.2 指令接口（只读、零延迟）

| 信号 | 方向 | 宽度 | 说明 |
|---|---|---|---|
| `imem_addr` | out | 32 | 字节地址，恒 4 字节对齐（`[1:0]==0`） |
| `imem_rdata` | in | 32 | 该地址处的 32 位指令字，**同周期有效**（组合读） |

### 3.3 数据接口（读写、零延迟读 + 同步写）

| 信号 | 方向 | 宽度 | 说明 |
|---|---|---|---|
| `dmem_addr` | out | 32 | 字节地址；RAM 侧按 `addr[31:2]` 取字 |
| `dmem_wdata` | out | 32 | 写数据位于**正确的字节车道**（lane-aligned），而非低位对齐 |
| `dmem_wstrb` | out | 4 | 字节写使能，与 `dmem_addr[1:0]` 及访问宽度一致 |
| `dmem_we` | out | 1 | 写使能（仅 SW/SH/SB 在 MEM 级拉高 1 周期） |
| `dmem_re` | out | 1 | 读使能（仅 LB/LH/LW/LBU/LHU 在 MEM 级拉高 1 周期） |
| `dmem_rdata` | in | 32 | 对齐后的 32 位读数据，**同周期有效**（组合读） |

**零延迟读是本版的设计选择**，理由与迁移路径见 `03-microarchitecture.md` §9 与 §11（已知限制）。

### 3.4 系统/测试接口（不属于 ISA，但属于交付接口）

| 信号 | 方向 | 宽度 | 说明 |
|---|---|---|---|
| `halt_i` | in | 1 | 系统请求停机：抹掉 MEM 级之后的年轻指令并冻结取指（用于 MMIO halt） |
| `trap_o` | out | 1 | 体系结构陷阱：电平保持，直到 `reset` |
| `trap_cause_o` | out | 4 | 陷阱原因码（RISC-V 标准编号，见 §5.1） |
| `trap_pc_o` | out | 32 | 触发陷阱的指令 PC |
| `retire_valid_o` | out | 1 | 退休脉冲（EX→MEM 提交点，每指令 1 拍） |
| `retire_pc_o` | out | 32 | 退休指令 PC |
| `retire_instr_o` | out | 32 | 退休指令编码 |

> 这组信号只做**可观测性**（验证、性能计数、波形调试），不参与数据通路决策；
> 综合时若不使用，可被优化掉（无扇出即被裁剪）。

---

## 4. 存储系统需求

- 32 位**字节寻址**地址空间；本版无 MMU / 无 Cache / 无虚实地址转换。
- 指令与数据分离的**哈佛接口**（同一物理存储器在 SoC 层实现，见 RTL 阶段）。
- Load/Store 全部 8 种组合必须正确：{LB,LH,LW,LBU,LHU} × {SB,SH,SW}。
- 有符号/无符号扩展必须正确；半字/字节访问不得破坏相邻字节。
- 写使能为**字节粒度**：`sb` 1 位、`sh` 2 位、`sw` 4 位，且位置由 `addr[1:0]` 决定。
- 地址计算使用 32 位模 2³² 回绕。

---

## 5. 异常、对齐与实现相关边界

### 5.1 陷阱模型（本项目的明确选择）

RV32I 要求「非法指令必须能被检测」，但本项目**不要求**特权 ISA、CSR、陷阱向量与
`mret`。因此采用 **fail-stop 陷阱模型**：

| 原因码 | 事件 | 检测级 |
|---|---|---|
| 0 | 指令地址未对齐（分支/JAL/JALR 目标 `[1:0] != 0`） | EX |
| 2 | 非法指令（RV32I 未定义编码） | EX |
| 3 | EBREAK | EX |
| 4 | Load 地址未对齐（宽度 > 字节且 `addr[1:0] != 0` / 半字 `addr[0] != 0`） | EX |
| 6 | Store 地址未对齐 | EX |
| 11 | ECALL（M-mode 环境调用） | EX |

行为：**精确陷阱** — 触发指令不退休（不写寄存器、不写内存、不产生 MMIO 副作用），
比它老的所有指令正常完成并退休，比它年轻的所有指令被抹除；随后 `trap_o` 保持高电平、
停止取指，直到 `reset`。原因码/PC 通过端口输出给系统。

> 选择理由：不引入 CSR/mtvec/mepc 等特权结构，同时保证「精确」这一最重要的正确性
> 属性（老的提交、年轻的抹除），并且 fail-stop 使状态完全确定、易于验证。

### 5.2 对齐策略（规范允许两种实现）

RISC-V 规范允许「硬件支持非对齐访问」或「触发地址非对齐异常」。本项目选择**触发陷阱**：
- 依据：优先级排序中「实现复杂度」高于「性能」，且非对齐硬件支持需要桶形移位器 +
  跨字拼接，是明确可以省掉的复杂度；
- 规范符合性：符合 RV32I 对非对齐访问的规定（属于实现定义、允许 trap）；
- 验证影响：验证程序不得使用非对齐访问；专门的边界测试用「期望值文件」而非与 ISS 比对
  （见 `06-verification-plan.md` §6）。

### 5.3 FENCE 的处理（唯一的宽松项，需评审确认）

单核、顺序、无 Cache 的微架构中 FENCE 不改变任何可观测行为，实现为 NOP。
`opcode=0001111` 的全部 funct3 编码（含 `FENCE.I` 的 `0x0000100F`）均按 NOP 处理。
严格来说 `FENCE.I` 属于 Zifencei，本项目不实现该扩展，但为与既有黄金模型保持一致而接受
其为 NOP；该宽松**不引入任何 ISA 语义错误**（NOP 是 FENCE 的合法退化实现）。

### 5.4 确定性需求

- 复位后 PC = `RESET_PC`，所有流水线寄存器 `valid=0`，寄存器堆清零（默认 `RF_INIT_EN=1`）。
- 不依赖任何上电未初始化状态；不存在由 X 值决定的行为（X 只能在非法仿真激励下出现）。
- 「指令存储器的内容」由外部提供，属于环境而非 CPU 状态。

---

## 6. 性能与实现需求

| 项 | 要求 | 本项目取舍 |
|---|---|---|
| 主频 | 早期草案 ≥ 100 MHz；后续澄清「不要求高主频」 | 设计目标：逻辑级数 ≤ ~15 LUT，**可达 ≥100 MHz**；不为其牺牲结构清晰度 |
| IPC/CPI | 不作要求 | 由微架构自然决定，给出解析模型 + 实测 CPI |
| Cache | 不要求 | 不实现 |
| 分支预测 | 不要求 | 静态预测（不跳转），EX 级解析 |
| 乱序/多发射 | 不要求 | 严格顺序、单发射 |
| 功耗 | 不要求 | 不做门控/多电压等优化 |
| 面积 | 不要求，但需报告 | 给出估算 + 结构统计 |

---

## 7. 验证需求（可验证性是第 3 优先级）

必须建立**自动化 PASS/FAIL** 的验证环境，覆盖：

1. Reset test
2. 每条 RV32I 指令的 directed test
3. Register test（含 x0 恒零）
4. ALU test
5. Load/Store test
6. Branch test
7. Jump test
8. Immediate test
9. Signed/unsigned test
10. Random instruction test
11. Corner-case test

必须显式验证：PC、寄存器堆、x0、ALU、立即数生成器、分支、跳转、Load/Store、
存储器接口（字节使能/符号扩展）、控制逻辑、以及**流水线冒险**（若存在流水线）。

工具约束：只用开源工具（Icarus Verilog 12 / Verilator 5 / GTKWave / Python 3），
不依赖商业 EDA；无 RISC-V GCC 时使用自带汇编器与指令集模拟器（见 `06`）。

---

## 8. 需求追踪矩阵（Requirement → Verification）

| ID | 需求 | 验证方法 | 具体工件（Phase 7 产出） |
|---|---|---|---|
| R01 | 复位确定性（PC/流水线/寄存器堆） | 单元 TB + 断言 | `tb/tb_reset.v` |
| R02 | x0 恒 0，写 x0 无副作用 | 单元 + directed 程序 | `tb_regfile.v`, `programs/reg_x0.S` |
| R03 | 10 条 R-type 语义 | ALU 单元 TB + 差分 | `tb_alu.v`, `programs/isa_alu.S` |
| R04 | 9 条 I-type ALU / 移位立即数 | ALU/立即数 TB + 差分 | `tb_alu.v`, `tb_immgen.v` |
| R05 | 5 条 Load（含符号/零扩展） | 单元 + directed + 差分 | `tb_ram.v`, `programs/loadstore.S` |
| R06 | 3 条 Store（字节使能正确） | 单元 + directed + 差分 | `tb_ram.v`, `programs/loadstore.S` |
| R07 | 6 条 Branch（有符号/无符号） | 比较器 TB + directed + 差分 | `tb_brcmp.v`, `programs/branch.S` |
| R08 | LUI/AUIPC（含 PC 相关性） | directed + 差分 | `programs/isa_upper.S` |
| R09 | JAL/JALR（链接值、目标、对齐） | directed + 差分 | `programs/jump.S` |
| R10 | 立即数生成器 5 种格式 | 穷举/随机单元 TB | `tb_immgen.v` |
| R11 | 非法指令检测与精确陷阱 | directed + 期望值比对 | `programs/trap_illegal.S` |
| R12 | 非对齐访问陷阱（原因 4/6） | directed + 期望值比对 | `programs/trap_misalign.S` |
| R13 | ECALL/EBREAK 行为 | directed + 期望值比对 | `programs/trap_env.S` |
| R14 | FENCE 退化为 NOP | directed + 差分 | `programs/isa_system.S` |
| R15 | 数据通路冒险正确（前递/停顿/冲刷） | 单元 + 覆盖率矩阵 + 随机差分 | `tb_hazard.v`, `programs/hazard_*.S`, `tools/gen_random.py` |
| R16 | 每条指令至少执行一次 | 覆盖率统计 | `tools/coverage.py` |
| R17 | 随机指令流等价性 | 数百组随机程序 vs 黄金模型 | `tools/gen_random.py` + `tools/check_equiv.py` |
| R18 | 边界情形（溢出、移位 0/31、0x8000…） | corner 程序 + 随机种子偏置 | `programs/corner.S` |
| R19 | 存储接口字节使能/对齐 | RAM 单元 TB 穷举 | `tb_ram.v` |
| R20 | 综合可实现性（无锁存/无多驱动/无不可综合结构） | Verilator lint + Yosys | `syn/` |

---

## 9. 工具与假设

| 工具 | 版本/状态 | 用途 |
|---|---|---|
| Icarus Verilog | 12.0 ✅ 已安装 | 主仿真器（`-g2005`） |
| Verilator | 5.036 ✅ 已安装 | lint（`--lint-only -Wall`）+ 资源统计 |
| GTKWave | ✅ 已安装 | 波形调试 |
| Python 3 | 3.13 ✅ | 汇编器、黄金模型、差分比对、随机程序生成 |
| Yosys | ❌ 未安装 | 综合/时序报告（见下） |
| RISC-V GCC | ❌ 未安装 | 用工作区自带 `rvai/sw/asm.py` 汇编器替代 |

**假设**：
- A1：允许复用工作区已有的独立 RV32I 汇编器与 ISS（`../rvai/sw/asm.py`、`../rvai/sw/iss.py`）
  作为黄金模型；它们是**独立实现**，符合「黄金模型不得由 DUT 派生」的要求。
  若评审要求完全自包含，Phase 7 可将两者内置为 `tools/`（约 1150 行）。
- A2：综合与时序报告需要 Yosys（或用户环境的 FPGA 工具）。若不可用，退化为
  Verilator `--stats` 结构统计 + 手工结构估算，并在报告中**明确标注为估算**（见 §9 风险）。

---

## 10. 风险与开放项

| # | 风险/开放项 | 影响 | 处置 |
|---|---|---|---|
| K1 | 零延迟（组合读）存储器不匹配 FPGA BRAM | FPGA 落地需小容量分布式 RAM 或增加 IF2 级 | §5.2 已定义为接口约束；给出迁移路径（`03` §11） |
| K2 | 无 Yosys → 无真实面积/时序数字 | 交付物 9/10/11 降级为估算 | 提供 `syn/*.ys` 脚本；报告中区分「实测」与「估算」 |
| K3 | 无 GCC → 测试程序规模受限 | 大程序（如排序/字符串）仍可手写 | 已用汇编方言覆盖；随机测试由生成器产生 |
| K4 | 非对齐访问与黄金模型行为不同 | 差分测试需排除该类用例 | 用期望值文件 + 文档标注为**有意差异** |
| K5 | FENCE.I 宽松处理（§5.3） | 与严格 RV32I 解释略有出入 | 已显式记录，等待评审确认 |

---

## 11. 评审要点（请架构负责人/用户确认）

1. **§5.1 fail-stop 陷阱模型**（不实现 CSR/trap vector）是否接受？
2. **§5.2 非对齐访问触发陷阱**是否接受？
3. **§5.3 FENCE/FENCE.I 全部退化为 NOP** 是否接受？
4. **§5.4 寄存器堆复位清零**（默认开启，可用参数关闭）是否接受？
5. **§8 K1：零延迟存储器接口**是否接受（FPGA 大容量实现需后续增补 ready 握手或 IF2 级）？

以上 5 项均已在 `03-microarchitecture.md` 中给出工程理由；如无异议，Phase 6 起按此实现。
