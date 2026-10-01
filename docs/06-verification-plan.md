# 06 — 验证计划（Phase 7 设计稿）

> **执行结果见 `07-verification-report.md`**：本文档是照此执行的计划，实际结果
> （190 个随种子、40/40 覆盖率、17 项缺陷记录、以及未覆盖项）在验证报告中给出。

> 目标：**自动化 PASS/FAIL**，覆盖规格书 §九 要求的 11 类测试，且能系统化覆盖全部流水线冒险。
> 工具：Icarus Verilog 12 + Verilator 5（lint）+ Python 3（汇编/黄金模型/比对）+ GTKWave（调试）。

---

## 1. 分层验证策略

| 层 | 名称 | 手段 | 判定方式 | 覆盖对象 |
|---|---|---|---|---|
| L0 | 单元测试 | 每模块独立 TB | 自检 + `$fatal`/错误计数 | ALU、比较器、立即数、译码器、寄存器堆、RAM、冒险单元、复位 |
| L1 | 定向程序测试 | 汇编程序跑在 SoC 上 | 程序内自检 + 日志标记 | 每条指令、边界情形、陷阱 |
| L2 | **差分等价测试** | RTL vs 独立 ISS | 事件日志逐行 diff + 寄存器/存储器逐字比对 | 全 ISA、数据通路整体 |
| L3 | 约束随机测试 | 随机程序生成器 + 差分 | 同上（数百种子） | 冒险组合、控制流组合 |
| L4 | 覆盖率统计 | 指令编码覆盖 + 冒险覆盖矩阵 | 覆盖率报告 | 确认「每条指令都跑过」「每条冒险都触发过」 |
| L5 | 回归 | `make all` | 全绿 + 退出码 | 防止修改引入回归 |

**设计原则**：L0 定位故障、L1 证明意图、L2/L3 用**独立实现的黄金模型**兜住「想不到的」错误。

---

## 2. 黄金模型与差分方法

- 黄金模型：工作区既有的独立 RV32I 指令集模拟器 `../rvai/sw/iss.py`（**从规范独立编写**，
  非由本 RTL 派生）与汇编器 `../rvai/sw/asm.py`；Phase 7 将其内置到 `tools/`（若评审要求自包含）。
- 事件日志格式（RTL TB 与 ISS 输出**逐字节一致**，从而 `diff` 即为判定）：

```
PUTC 41                 ← putchar：[7:0]
MARK DEADBEEF           ← 标记写
HALT 00                 ← 停机（MMIO halt / EBREAK）
TRAP ecall              ← 陷阱（原因与文本）
CHECKSUM 1A2B3C4D       ← 运行结束后全存储器 FNV-1a 校验和
STEPS 1234              ← 执行/退休的指令条数
```

- **状态比对**（比日志更强）：TB 额外导出 `REGS`（32×32bit）与 `MEM`（全部字），
  `check_equiv.py` 用同一镜像运行 ISS 并逐字比较寄存器堆与存储器。
- **计数口径**：RTL 的 `retire` 定义在 EX→MEM 提交点；ISS 的 `STEPS` 不包含触发
  halt/trap 的那条指令。TB 据此换算，使两侧 `STEPS` 可直接比对（差异换算在 TB 内注释说明）。
- **有意差异**（不参与差分，改用期望值文件）：
  | 差异 | 原因 |
  |---|---|
  | 非对齐访存 | RTL 触发陷阱（规范允许），ISS 按字节粒度执行 |
  | `0x1000_000C` 周期计数 | ISS 不建模时序，恒返回 0 |
  | 非法指令的文本 | ISS 的部分错误文本与 RTL 原因码表示法不同（仅比对原因类别） |

---

## 3. 自动化判定

- 每个程序：`make sim` 生成 `sim/rtl_<name>.log`，`make iss` 生成 `sim/iss_<name>.log`，
  `make diff` 执行 `diff -u`；**不一致即 FAIL 且退出码非 0**，并打印首个差异上下文。
- 单元 TB：内部维护 `errors` 计数，结束打印 `PASS/FAIL`，FAIL 时 `$fatal` 使 `vvp` 返回非 0。
- 超时：TB 内置周期上限（可用 `+max_cycles=` 覆盖），超时打印 `TIMEOUT` 并 FAIL。
- 全量回归：`make all` 串联全部层次，任何一步失败立即停止。

---

## 4. 测试清单（对应规格书 11 类要求）

| # | 规格要求 | 工件 | 判定 |
|---|---|---|---|
| 1 | Reset test | `tb/unit/tb_reset.v` + `programs/reset_first.S` | 复位后 PC/流水线/寄存器堆确定；首条指令 5 拍完成；无副作用 |
| 2 | 每条指令 directed test | `programs/isa_alu.S`(R 型 10 条)、`isa_imm.S`(9 条)、`isa_loadstore.S`(8 条)、`isa_branch.S`(6 条)、`isa_upper.S`(LUI/AUIPC)、`isa_jump.S`(JAL/JALR)、`isa_system.S`(FENCE/ECALL/EBREAK) | 程序内自检 + 差分 |
| 3 | Register test | `tb/unit/tb_regfile.v` + `programs/reg_x0.S` | x0 恒零、写 x0 无副作用（含前递路径 rd=0 门控） |
| 4 | ALU test | `tb/unit/tb_alu.v` | 11 种操作 × 定向向量 + 随机 20 万组 vs 行为级参考 |
| 5 | Load/Store test | `tb/unit/tb_ram.v` + `programs/loadstore.S` | 5 载入 × 3 存储 × 4 车道偏移；符号扩展边界；相邻字节不受损 |
| 6 | Branch test | `tb/unit/tb_brcmp.v` + `programs/branch.S` | 6 分支 × 采纳/不采纳 × 前向/后向；有符号/无符号边界 |
| 7 | Jump test | `programs/jump.S` | JAL/JALR 链接值、目标、`&~1`、嵌套调用、跳转表 |
| 8 | Immediate test | `tb/unit/tb_immgen.v` + `programs/isa_imm.S` | I/S/B/U/J 五格式 × 正负边界 × 位 0 强制 0 |
| 9 | Signed/unsigned test | `programs/signedness.S` | SLT/SLTU、BLT/BGE vs BLTU/BGEU、LB/LBU、LH/LHU 在 0x7F/0x80/0x7FFF/0x8000 |
| 10 | Random instruction test | `tools/gen_random.py` + `make random SEEDS=N` | 差分（日志 + 全状态） |
| 11 | Corner-case test | `programs/corner.S` + 随机偏置种子 | 见 `04` §6 的 E1–E20 清单 |

### 4.1 冒险覆盖矩阵（L4 核心）

| 冒险 | 场景 | 覆盖用例 |
|---|---|---|
| H1 | 生产者 EX/MEM → 使用者 EX（距离 1，ALU） | `programs/hazard_fwd.S`、`isa_alu.S`、随机种子 |
| H1 | 距离 1 且 rd 相同但使用者不用该寄存器 | 同上（验证 `uses_*` 不产生伪命中） |
| H2 | 生产者 MEM/WB → 使用者 EX（距离 2） | `programs/hazard_fwd.S` |
| H3 | 生产者 WB ↔ 使用者 ID 同拍（距离 3，**写穿透**） | `programs/hazard_wbthru.S`（专项，最易漏） |
| H4 | Load → 紧邻使用者（rs1 / rs2 / 分支 / store 数据 4 种形态） | `programs/hazard_loaduse.S` |
| H4 反例 | Load 后接 `LUI/JAL`（rs 字段是立即数） | `programs/hazard_loaduse.S`（**不得停顿**，用周期数断言） |
| H5 | 采纳分支冲刷 2 拍 / 不采纳 0 拍 | `programs/branch.S` + 周期计数比对 |
| H5 | JAL 冲刷、JALR 冲刷 | `programs/jump.S` |
| H6 | Store 数据依赖（距离 1/2/3） | `programs/hazard_store.S` |
| — | 停顿与重定向同拍（优先级） | `programs/hazard_priority.S` |
| — | 陷阱与在途指令（精确性：老的提交、年轻的抹除） | `programs/trap_precise.S` |
| — | 停机与在途指令（年轻指令无副作用） | `programs/halt_drain.S` |

覆盖率由 `tools/coverage.py` 汇总：**每条 RV32I 编码至少执行一次**、上述每一行至少命中一次；
未覆盖项在最终验证报告中列出并说明原因。

---

## 5. 随机测试设计（L3）

- 生成器约束：
  - 仅产生 RV32I 合法编码（不产生陷阱，除非专门的陷阱测试）；
  - 所有控制转移**只向前**（保证程序必然到达结尾的停机指令，避免死循环）；
  - 访存仅使用固定的基址寄存器 x8（小偏移），保证地址落在数据区且对齐；
  - 寄存器使用 x1–x31（x0 作为源操作数按概率注入）；
  - 指令混合比例偏向「制造冒险」：高比例的距离 1/2/3 依赖、Load→使用、分支→依赖。
- 每个种子：随机长度 200–2000 条指令 + 结尾 `sw x0, 0(x0)` 之外的停机序列（写 MMIO halt）。
- 判定：日志 diff + 寄存器堆/存储器全量比对；失败时自动保存 `.hex`、日志、波形并由 `make` 报出种子号。
- 规模：默认 200 种子，每种子 ≤ 2000 条指令（分钟级）。

---

## 6. 单元测试要点（L0）

| TB | 关键判定 |
|---|---|
| `tb_alu.v` | 11 种操作；边界操作数（0, 1, -1, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF）；移位 0/31；SLT vs SLTU 分歧点；随机 vs 参考模型 |
| `tb_brcmp.v` | 6 种条件 ×（等于/小于/大于）×（有符号/无符号边界） |
| `tb_immgen.v` | 5 种格式；正负边界（-2048/-1/0/2047）；B/J 位 0 恒 0；U 型低 12 位恒 0；随机指令字段 |
| `tb_decoder.v` | 每条指令的完整 24 位控制字期望值；非法编码 → `CTRL_ILLEGAL`；`uses_rs1/rs2` 表 |
| `tb_regfile.v` | x0 读写；写使能；双读口；**写穿透**（同拍同址读写）；不同址不穿透 |
| `tb_ram.v` | 4 种 `wstrb` 组合 × 4 车道；读改写一致性；越界读 0/写忽略 |
| `tb_hazard.v` | `stall` 与 `fwd_*` 的**完整真值表**穷举（有限输入空间：有效位 × rd 号 × 使用位） |
| `tb_reset.v` | 复位期间无写操作；复位后 PC/流水线寄存器值；`x0=0` |

---

## 7. 与综合相关的检查（Phase 9 前置）

| 检查 | 工具/手段 | 通过标准 |
|---|---|---|
| 语法与可综合性 | `iverilog -g2005`（零警告 `-Wall`） | 无错误/无警告 |
| Lint | `verilator --lint-only -Wall -Wno-fatal`（严格模式） | 零 warning（含 `UNOPTFLAT`、`LATCH`、`WIDTH`） |
| 锁存器 | Verilator `LATCH` 检查 | 无 |
| 多驱动/组合环 | Verilator `MULTIDRIVEN`/`UNOPTFLAT` | 无 |
| 位宽 | Verilator `WIDTH` | 无隐式截断 |
| 资源统计 | `verilator --stats` | 输出 FF/LUT 估计，写入报告 |
| 真实综合 | `syn/yosys.ys`（若用户环境有 Yosys） | 综合通过 + 单元面积/时序报告 |

---

## 8. 交付报告（Phase 10 汇总）

1. 验证报告：测试清单执行结果、覆盖率、差分种子数、发现并修复的缺陷列表；
2. 综合报告：工具、脚本、资源统计（区分**实测**与**估算**）；
3. 时序报告：关键路径分析（无商业工具时的结构化估算 + Yosys 可用时的实测）；
4. 面积/资源报告；
5. 已知限制与未来改进（`03` §12）；
6. 复位到首指令时序分析（`04` §3）；
7. 五条典型指令的数据通路分析（`04` §4）。

---

## 9. 风险与对策

| 风险 | 对策 |
|---|---|
| 黄金模型与 RTL 同时误解规范 | 追加第三来源：对关键指令（移位、SLT/U、符号扩展）在 `tb_alu.v` 内独立行为级模型 + 手工期望值 |
| 差分测试因日志格式细节失败 | 日志格式由「同一份格式说明」驱动，首次运行即校准 |
| 随机测试覆盖不到写穿透等长距离冒险 | 生成器显式偏置距离 3 依赖；另有 `hazard_wbthru.S` 专项 |
| 无 Yosys → 无时序数字 | 报告中明确标注为结构化估算；提供脚本供用户环境复现 |
| 手写汇编出错 | 汇编器自带 `test_asm.py` 自测；程序内自检 + 差分双重判定 |
