# rv32i-cpu — 五级流水线 RV32I 处理器

单核、顺序、单发射的 **RISC-V RV32I** 处理器。Verilog-2001/2005 实现，无厂商 IP，
只用开源工具（Icarus Verilog / Verilator / GTKWave / Python 3）即可完成仿真、
差分验证、覆盖率统计与 lint。

**设计优先级**：ISA 正确性 > RTL 正确性 > 可验证性 > 结构清晰 > 可实现性 > 性能 > 面积 > 功耗。

---

## 当前状态：**RTL 完成，验证全绿**

| 验证层次 | 规模 | 结果 |
|---|---|---|
| 单元测试（8 个 TB） | ALU / 分支比较器 / 立即数 / 译码器 / 寄存器堆 / 冒险单元 / RAM / 复位 | **PASS** |
| 定向程序（23 个） | 每条 RV32I 指令 + 冒险专项 + 边界 + 陷阱 | **PASS** |
| 差分等价（vs 独立 ISS） | 20 个程序 ×（事件日志 + 32 寄存器 + 16384 字存储器） | **PASS** |
| 期望值测试（有意差异） | 3 个非对齐陷阱程序 | **PASS** |
| 约束随机差分 | **190 个种子**（≈13.4 万条随机指令） | **PASS** |
| 指令覆盖率（RTL retire 端口实测） | **40 / 40 条 RV32I 编码** | **COMPLETE** |
| lint / 可综合性 | Icarus `-Wall` + Verilator `-Wall` | **零警告** |

RTL 功能逻辑在首轮仿真即通过全部差分与随机测试；发现并修复的 17 项问题全部位于
测试程序、测试平台、构建脚本，以及两处由 lint 触发的结构改进。清单见
[验证报告](docs/07-verification-report.md) §7。

---

## 微架构一览

```
IF ──► ID ──► EX ──► MEM ──► WB
```

| 项 | 决策 |
|---|---|
| 流水线 | 5 级顺序单发射，哈佛接口（I/D 独立），无 Cache |
| 冒险 | EX/MEM→EX、MEM/WB→EX 双路前递 + **寄存器堆写穿透** + Load-Use 单拍互锁（封闭 6 条，见 `03` §6） |
| 控制转移 | 分支/JAL/JALR 全部在 **EX** 解析；静态预测不跳转；采纳时冲刷 **2 拍** |
| 提交点 | EX→MEM 边界（EX 是唯一陷阱源 ⇒ 进入即必然完成，退休计数与陷阱无歧义） |
| 陷阱 | fail-stop 精确陷阱：非法指令(2)/EBREAK(3)/非对齐(4,6)/ECALL(11)/目标非对齐(0)，输出 `trap_cause/trap_pc/trap_tval` |
| 存储器 | 组合读 + 同步写 + 4 位字节使能；非对齐访问触发陷阱（规范允许） |
| 寄存器堆 | 32×32，2 读 1 写，x0 硬零，复位清零（`RF_INIT_EN` 可关） |
| 规模 | 1605 触发器 + 约 900–1300 LUT（估算）；RTL 1326 行 |
| 性能 | 实测 CPI：纯 ALU 1.04、访存 1.09、分支密集 1.66（详见 `08` §5） |
| 扩展 | 无 M/A/F/D/C、无 CSR、无特权模式、无中断（严格 RV32I） |
| 语言 | Verilog-2001/2005 可综合子集（无 SystemVerilog、无厂商原语、无三态、单时钟域同步复位） |

---

## 快速开始

```sh
make lint                 # Icarus -Wall + Verilator -Wall（必须零警告）
make unit                 # 8 个模块级自检 TB
make diff                 # 汇编 + RTL 仿真 + 参考模型 + 日志/全状态比对（23 个程序）
make random SEEDS=150     # 约束随机差分回归
make cov                  # 指令覆盖率（必须 40/40）
make all                  # 以上全部
make wave P=isa_loadstore # GTKWave 查看波形
```

依赖：`iverilog`(≥11) `verilator`(≥5) `gtkwave` `python3`；Yosys 可选（`make syn`）。

---

## 目录结构

```
rv32i-cpu/
├── docs/                    设计文档与报告
│   ├── 01-requirements.md       需求分析与需求追踪矩阵
│   ├── 02-architecture-space.md 微架构方案比较与选型
│   ├── 03-microarchitecture.md  微架构规格书（含 ADR 决策记录）
│   ├── 04-datapath-control.md   数据通路/控制通路 + 复位时序 + 5 条指令逐拍分析
│   ├── 05-module-interfaces.md  模块划分与冻结接口
│   ├── 06-verification-plan.md  验证计划
│   ├── 07-verification-report.md 验证报告（结果、缺陷记录、未覆盖项）
│   └── 08-synthesis-area-timing.md 综合/面积/时序/CPI 报告
├── rtl/
│   ├── include/rv32i_defs.vh    常量、控制字位域、陷阱原因码
│   ├── core/rv32i_cpu.v         五级流水线内核（唯一复杂状态模块）
│   ├── alu/                     rv32i_alu.v, rv32i_brcmp.v
│   ├── regfile/                 rv32i_regfile.v（含写穿透）
│   ├── control/                 decoder / immgen / hazard
│   ├── memory/                  rv32i_ram.v（字节使能写 + 组合读）
│   └── soc/                     rv32i_soc.v（内核 + 双存储器 + MMIO）
├── tb/
│   ├── tb_rv32i.v               SoC 级自检 TB（事件日志 + 状态导出 + 执行轨迹）
│   ├── unit/                    8 个模块级自检 TB
│   └── programs/                23 个定向汇编程序（+3 个 .expected）
├── tools/                       lint_asm / gen_random / run_random / run_diff /
│                                check_equiv / coverage / ff_count
├── syn/                         Yosys 综合脚本与说明
└── build/                       仿真产物（*.hex/.log/.state/.out）
```

---

## 验证方法（要点）

1. **单元层**：每模块独立自检；ALU/冒险单元另做 2 万组随机性质检查。
2. **定向层**：每条指令 + 冒险专项（H1/H2/H3/H4/H6）+ 边界（`04` §6 的 E1–E20）+ 陷阱。
3. **差分层**：与工作区内**独立实现**的 RV32I 指令集模拟器比对——事件日志逐行、
   寄存器与整块存储器逐字；程序自检失败即使两边一致也判 FAIL。
4. **随机层**：约束随机（只前向控制流保证可终止、访存固定基址且对齐、操作数按
   前 1/2/3 条指令的目的寄存器偏置以命中 H1/H2/H3）。
5. **覆盖率**：用 RTL 自己的 retire 端口统计实际执行过的编码，40/40。

---

## 已知限制（详见 `08` 与 `03` §12）

- 存储器为**零延迟组合读**：FPGA 大容量实现需分布式 RAM，或增加 ready 握手 / IF2 级；
- 无 CSR / 特权模式 / 中断；非对齐访存触发陷阱；无 M 扩展；
- 控制转移固定 2 拍惩罚（无分支预测，符合规格要求）；
- 面积/时序为**结构估算**（本机无 Yosys），提供 `syn/` 脚本以获取实测值。

## 外部依赖

汇编器与参考模型是**与本工程 RTL 独立编写**的 RV32I 工具链（差分验证的黄金模型），
已随仓库提供在 `tools/vendor/`，因此**克隆后即可直接构建，无需其它仓库**：

| 文件 | 作用 |
|---|---|
| `tools/vendor/asm.py` | 汇编 `tb/programs/*.S` 为 `$readmemh` 镜像 |
| `tools/vendor/iss.py` | 独立 RV32I 指令集模拟器（差分比对的黄金模型） |

开发时若隔壁存在 `../rvai/sw`，`Makefile` 亦可回退使用它（`RVAI_DIR` 可覆盖）；
`make vendor` 从该处刷新副本，刷新后请重跑 `make all`。来源与校验和见
`tools/vendor/README.md`。

**工具链要求**：`iverilog` ≥ 11、`verilator` ≥ 5、`gtkwave`、`python3`（仅标准库）；
`yosys` 可选（只有 `make syn` 与真实面积/时序数字需要它）。

## 许可证

MIT，见 [LICENSE](LICENSE)。

`tools/vendor/` 下的汇编器与参考模型来自同一作者的 rvai 项目，采用同一许可证，
且保持与来源逐字节一致（校验和见 `tools/vendor/README.md`）；其余 RTL、testbench、
测试程序、工具与文档均为本工程原创。
