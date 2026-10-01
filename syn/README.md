# syn/ — 综合与时序脚本

本工程的 RTL **不依赖任何厂商 IP 或综合属性**，可以用任意标准综合器读入。
本目录提供 Yosys 脚本，用于在安装 Yosys 的环境里得到**真实的面积/资源数字**
（本机未安装 Yosys，因此 `docs/08-synthesis-area-timing.md` 中的面积与时序是结构估算）。

## 用法

```sh
brew install yosys          # macOS；其它平台用相应包管理器
make syn                    # 等价于: yosys -q syn/rv32i_soc.ys
```

脚本流程：

1. `read_verilog` 读入全部 RTL（含 `-Irtl/include`，供 `rv32i_defs.vh` 使用）；
2. `hierarchy -top rv32i_soc`；
3. 通用综合：`proc / opt / fsm / memory -nomap / opt -full / techmap / opt -fast`；
4. 报告：`stat`、`stat -width`、`ltp`（最长拓扑路径，用于快速估计关键路径级数）。

## 得到工艺相关数字

脚本末尾预留了三种工艺映射（取消注释即可）：

```tcl
synth_xilinx -top rv32i_soc     # 7 系列：LUT/FF/BRAM 利用率
synth_ice40  -top rv32i_soc     # iCE40
synth_ecp5   -top rv32i_soc     # ECP5
stat
```

若要做门级面积/时序，需要工艺库：

```sh
yosys -p "read_verilog ...; synth; abc -liberty your.lib; stat"
```

## 阅读综合结果的提示

- `rv32i_ram` 的两个实例（指令/数据）会被映射为 **BRAM 或分布式 RAM**，取决于容量
  （`MEM_WORDS` 参数）。默认 16384 字 × 2 = 128 KiB，对多数 FPGA 偏大——若目标是
  实际下载到板卡，请把 `MEM_WORDS` 调小（例如 4096）或把存储器移到片外。
- 本设计的存储器接口是**组合读**（零延迟），因此综合器会推断成 LUTRAM/分布式 RAM。
  若必须用 BRAM（同步读），需要给 IF 级增加第二拍或为数据侧增加 ready 握手，
  见 `docs/03-microarchitecture.md` §12 的 L1。
- 综合后如果出现 latch 警告，说明有人改坏了 `always @(*)` 的默认赋值，属于回归，
  应立刻用 `make lint` 复查。
