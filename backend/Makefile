include ../Makefile.base

ifdef BLUERDMA_IMMFAIL_ENABLE_TIME
MISCFLAGS += -D BLUERDMA_IMMFAIL_ENABLE_TIME=$(BLUERDMA_IMMFAIL_ENABLE_TIME)
endif

TCLDIR ?= xdc
CLK ?= rdma_clock
OOC ?= 1

BACKENDDIR ?= $(shell readlink -f ./)
QUARTUS_BACKEND_DIR ?= $(BACKENDDIR)/quartus
VIVADO_BACKEND_DIR ?= $(BACKENDDIR)/vivado

# If QUARTUS_WORKDIR_NAME is set, use it as the directory name under BACKENDDIR.
# Otherwise fall back to a timestamped name.
# Usage: make quartus QUARTUS_WORKDIR_NAME=my_existing_workdir
ifdef QUARTUS_WORKDIR_NAME
QUARTUS_WORKDIR := $(BACKENDDIR)/$(QUARTUS_WORKDIR_NAME)
else
QUARTUS_WORKDIR := $(BACKENDDIR)/quartus_workdir_$(shell date +"%Y-%m-%d-%H-%M-%S-%N")
endif
VIVADO_WORKDIR ?= $(BACKENDDIR)/vivado_workdir_$(shell date +"%Y-%m-%d-%H-%M-%S-%N")

RTL_DIRS ?= $(BACKENDDIR)/verilog/*.v\
			$(BACKENDDIR)/../src/verilog/*.v \
			$(BACKENDDIR)/../src/verilog/**/*.v \
			$(BACKENDDIR)/quartus/rtl/*.v

QUARTUS_SDC_DIRS ?= $(QUARTUS_BACKEND_DIR)/sdc/*.sdc
VIVADO_SDC_DIRS ?= $(VIVADO_BACKEND_DIR)/sdc/*.sdc

			
LOGFILE ?= run.log
RUNTOPHASE ?= all # synth place route all
DEVICE ?= AGIB027R29B1E2V
FAMILY ?= Agilex 7

VIVADO_PART ?= xcvu13p-fhgb2104-2L-e



ifeq ($(BLUERDMA_BUILD_TARGET), XILINX_100G)
	BSVSRCDIR += -p +:$(abspath ../src/vendor/xilinx)
	RTL_DIRS += $(BACKENDDIR)/vivado/rtl/*.v
	VIVADO_SDC_DIRS += $(VIVADO_BACKEND_DIR)/sdc/xilinx_100g/*.sdc
else ifeq ($(BLUERDMA_BUILD_TARGET), ALTERA_400G)
	BSVSRCDIR += -p +:$(abspath ../src/vendor/altera)
	RTL_DIRS += $(BACKENDDIR)/quartus/rtl/*.v
	VIVADO_SDC_DIRS += $(QUARTUS_BACKEND_DIR)/sdc/*.sdc
endif

ifeq ($(BLUE_RDMA_DMA_IP_TYPE), XILINX_BLUE_DMAC)
	VIVADO_SDC_DIRS += $(VIVADO_BACKEND_DIR)/sdc/xil_blue_dmac/*.sdc
endif

# TARGETFILE ?= ../test/TestFullyPipelinedUpdateBram.bsv
# BSV_TOP_MODULE ?= mkTestFullyPipelinedBackendTimingTest

# TARGETFILE ?= ../test/TestFullyPipelinedUpdateBram.bsv
# BSV_TOP_MODULE ?= mkTestFullyPipelinedUpdateBramFunctionalTest

# TARGETFILE ?= ../test/TestSdpBramWrapper.bsv
# BSV_TOP_MODULE ?= mkTestSdpBramWrapperConflictReadWriteTest

# TARGETFILE ?= ../test/TestSdpBramWrapper.bsv
# BSV_TOP_MODULE ?= mkTestAcxBram72kSdpConflictRW

# TARGETFILE ?= ../test/TestButterflyMerge.bsv
# BSV_TOP_MODULE ?= mkTestFourChannelButterflyMergeTimingTest

# TARGETFILE ?= ../test/TestNapWrapper.bsv
# BSV_TOP_MODULE ?= mkTestEthernetNapLoopBack

# TARGETFILE ?= ../test/TestEthernetFrameIO.bsv
# BSV_TOP_MODULE ?= mkTestEthernetFrameIoTiming

# TARGETFILE ?= ../test/TestAddressChunker.bsv
# BSV_TOP_MODULE ?= mkTestAddressChunkerTiming

# TARGETFILE ?= ../test/TestPayloadGenAndCon.bsv
# BSV_TOP_MODULE ?= mkTestPayloadGenAndConTiming

# TARGETFILE ?= ../test/TestPsnContinousChecker.bsv
# BSV_TOP_MODULE ?= mkTestBitmapWindowStorageTiming

# TARGETFILE ?= ../test/TestAutoAckGenerator.bsv
# BSV_TOP_MODULE ?= mkTestAutoAckGeneratorTiming

# TARGETFILE ?= ../src/RTilePcieAdaptor.bsv
# BSV_TOP_MODULE ?= mkRTilePcieAdaptor

# TARGETFILE ?= ../test/TestRTilePcieAdaptor.bsv
# BSV_TOP_MODULE ?= mkTestPcieRxStreamSegmentForkTimingTest

# TARGETFILE ?= ../test/TestRTilePcieAdaptor.bsv
# BSV_TOP_MODULE ?= mkTestPcieHwCpltBufferAllocatorTimingTest

# TARGETFILE ?= ../test/TestRTilePcieAdaptor.bsv
# BSV_TOP_MODULE ?= mkTestPcieCompletionBufferTimingTest

# TARGETFILE ?= ../test/TestRTilePcieAdaptor.bsv
# BSV_TOP_MODULE ?= mkTestRtilePcieAdaptorTimingTest

# TARGETFILE ?= ../test/TestFTileMacAdaptor.bsv
# BSV_TOP_MODULE ?= mkTestFtileMacRxPingPongSingleChannelProcessorTimingTest

# TARGETFILE ?= ../src/FTileMacAdaptor.bsv
# BSV_TOP_MODULE ?= mkFtileMacRxPingPongChannelMetaJoin

# TARGETFILE ?= ../test/TestFTileMacAdaptor.bsv
# BSV_TOP_MODULE ?= mkTestFtileMacRxPingPongChannelMetaJoinTimingTest

# TARGETFILE ?= ../test/TestFTileMacAdaptor.bsv
# BSV_TOP_MODULE ?= mkTestFtileMacAdaptorTimingTest

# TARGETFILE ?= ../test/TestFTileMacAdaptor.bsv
# BSV_TOP_MODULE ?= mkTestRotateTimingTest

# TARGETFILE ?= ../test/TestFTileMacAdaptor.bsv
# BSV_TOP_MODULE ?= mkTestMimoTimingTest

# TARGETFILE ?= ../test/TestFTileMacAdaptor.bsv
# BSV_TOP_MODULE ?= mkTestFtileMacTxPingPongForkTimingTest

# TARGETFILE ?= ../test/TestFTileMacAdaptor.bsv
# BSV_TOP_MODULE ?= mkTestFtileMacCocotbLoopBackTest

# TARGETFILE ?= ../test/TestDtldStream.bsv
# BSV_TOP_MODULE ?= mkTestDtldStreamConcatorTimingTest

# TARGETFILE ?= ../test/TestDtldStream.bsv
# BSV_TOP_MODULE ?= mkTestDtldStreamSpliterTimingTest

# TARGETFILE ?= ../test/TestCsrFramework.bsv
# BSV_TOP_MODULE ?= mkTestCsrNodeTiming

# TARGETFILE ?= ../test/TestTop.bsv
# BSV_TOP_MODULE ?= mkTestTopTimingNoHardIP

# TARGETFILE ?= ../test/TestTop100G.bsv
# BSV_TOP_MODULE ?= mkTestTopTimingNoHardIP

# TARGETFILE ?= ../src/Top.bsv
# BSV_TOP_MODULE ?= mkBsvTop
# TOP = bluerdma_top

TARGETFILE ?= ../src/Top.bsv
BSV_TOP_MODULE ?= mkBsvTop
TOP = bluerdma_top

BSC_SOURCE_FILES := $(shell find $(abspath ../src) $(abspath ../test) -type f -name '*.bsv')
BACKEND_BUILD_DEPS := $(BACKENDDIR)/Makefile $(BACKENDDIR)/../Makefile.base
VERILOG_HELPERS := \
	$(BACKENDDIR)/reset_tree_wrapper.py \
	$(BACKENDDIR)/apply_reset_signal_patch.py \
	$(BACKENDDIR)/listVlogFiles.tcl
BACKEND_CONFIG_VARS := \
	TARGETFILE \
	BSV_TOP_MODULE \
	BLUERDMA_BUILD_TARGET \
	BLUE_RDMA_DMA_IP_TYPE \
	BLUE_RDMA_ETH_IP_TYPE \
	IS_COMPILE_FOR_SIM \
	BLUERDMA_IMMFAIL_ENABLE_TIME
BACKEND_CONFIG_RAW := $(foreach v,$(BACKEND_CONFIG_VARS),$(v)=$($(v))|)
BACKEND_CONFIG_HASH := $(shell printf '%s' '$(BACKEND_CONFIG_RAW)' | sha1sum | cut -c1-12)
BACKEND_CONFIG_KEY := $(BSV_TOP_MODULE)__$(BLUERDMA_BUILD_TARGET)__$(BACKEND_CONFIG_HASH)
CONFIG_CACHE_ROOT := $(BACKENDDIR)/config_cache
CONFIG_CACHE_DIR := $(CONFIG_CACHE_ROOT)/$(BACKEND_CONFIG_KEY)
CONFIG_BUILD_DIR := $(CONFIG_CACHE_DIR)/build
CONFIG_VERILOG_DIR := $(CONFIG_CACHE_DIR)/verilog
SHARED_BUILD_DIR := build
SHARED_VERILOG_DIR := $(BACKENDDIR)/verilog
COMPILE_STAMP := $(CONFIG_BUILD_DIR)/.compile.stamp
VERILOG_STAMP := $(CONFIG_VERILOG_DIR)/.verilog.stamp
SHARED_COMPILE_STAMP := $(SHARED_BUILD_DIR)/.active_compile_$(BACKEND_CONFIG_KEY)
SHARED_VERILOG_STAMP := $(SHARED_VERILOG_DIR)/.active_verilog_$(BACKEND_CONFIG_KEY)

BUILDDIR := $(CONFIG_BUILD_DIR)
OUTDIR := -bdir $(BUILDDIR) -info-dir $(BUILDDIR) -simdir $(BUILDDIR) -vdir $(BUILDDIR)
DIRFLAGS := $(BSVSRCDIR) $(OUTDIR) $(WORKDIR)




MAX_NET_PATH_NUM ?= 10000
TOP ?= $(BSV_TOP_MODULE)

export QUARTUS_WORKDIR
export QUARTUS_BACKEND_DIR
export QUARTUS_SDC_DIRS
export VIVADO_WORKDIR
export VIVADO_BACKEND_DIR
export VIVADO_SDC_DIRS
export VIVADO_PART
export PROJ_NAME = $(BSV_TOP_MODULE)
export REV_NAME = rev1
export TOP
export RTL_DIRS
export DEVICE
export FAMILY
export DIR_BSV_GENERATED = $(CONFIG_VERILOG_DIR)

export BLUE_RDMA_DMA_IP_TYPE
export BLUE_RDMA_ETH_IP_TYPE


ifdef IS_COMPILE_FOR_SIM
	MISCFLAGS += -D IS_COMPILE_FOR_SIM
endif

define sync_shared_dir
	@mkdir -p "$(2)"; \
	find "$(2)" -mindepth 1 -exec rm -rf {} +; \
	if test -d "$(1)"; then \
		cp -a "$(1)"/. "$(2)/"; \
	fi; \
	rm -f "$(2)"/.active_compile_* "$(2)"/.active_verilog_*; \
	touch "$(3)"
endef

$(COMPILE_STAMP): $(BSC_SOURCE_FILES) $(BACKEND_BUILD_DEPS)
	mkdir -p $(CONFIG_BUILD_DIR)
	# rm $(CONFIG_BUILD_DIR)/FullyPipelineChecker.bo
	bsc -elab -verilog -verbose $(BLUESIMFLAGS) $(DEBUGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -g $(BSV_TOP_MODULE) $(TARGETFILE)
	touch $@

$(SHARED_COMPILE_STAMP): $(COMPILE_STAMP)
	$(call sync_shared_dir,$(CONFIG_BUILD_DIR),$(SHARED_BUILD_DIR),$@)

compile: $(SHARED_COMPILE_STAMP)

$(VERILOG_STAMP): $(COMPILE_STAMP) $(VERILOG_HELPERS)
	mkdir -p $(CONFIG_VERILOG_DIR)
	bsc $(VERILOGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(TRANSFLAGS) -g $(BSV_TOP_MODULE) $(TARGETFILE)
	bluetcl listVlogFiles.tcl -bdir $(CONFIG_BUILD_DIR) -vdir $(CONFIG_BUILD_DIR) $(BSV_TOP_MODULE) $(BSV_TOP_MODULE) | grep -i '\.v' | xargs -I {} cp {} $(CONFIG_VERILOG_DIR)
	python3 ./reset_tree_wrapper.py $(CONFIG_VERILOG_DIR)/mkSqGroup.v
	python3 ./reset_tree_wrapper.py $(CONFIG_VERILOG_DIR)/mkRqGroup.v
	# mkBsvTopOnlyHardIp contains RTile HIP primitives; bluetcl may not copy it automatically
	test -f $(CONFIG_BUILD_DIR)/mkBsvTopOnlyHardIp.v && cp $(CONFIG_BUILD_DIR)/mkBsvTopOnlyHardIp.v $(CONFIG_VERILOG_DIR)/ || true
	test -f $(CONFIG_VERILOG_DIR)/mkBsvTopOnlyHardIp.v && python3 ./reset_tree_wrapper.py $(CONFIG_VERILOG_DIR)/mkBsvTopOnlyHardIp.v || true
	python3 ./apply_reset_signal_patch.py $(CONFIG_VERILOG_DIR)
	touch $@

$(SHARED_VERILOG_STAMP): $(VERILOG_STAMP) $(SHARED_COMPILE_STAMP)
	$(call sync_shared_dir,$(CONFIG_VERILOG_DIR),$(SHARED_VERILOG_DIR),$@)

verilog: $(SHARED_VERILOG_STAMP)

print-config-key:
	@echo $(BACKEND_CONFIG_KEY)

print-config-verilog-dir:
	@echo $(abspath $(CONFIG_VERILOG_DIR))

# TODO: refactor 后未实际执行 Vivado / Quartus 的长时硬件编译验证。
# 当前路径协议保持不变，下游仍消费共享 backend/verilog/*.v，共享镜像
# 在进入硬件后端前会先由 verilog 目标刷新，理论上大概率可正常工作。
vivado: verilog
	cd vivado && \
	vivado -mode tcl -nolog -nojournal -source ./build_top.tcl 2>&1 | tee $(LOGFILE)

vivado_ooc: verilog
	cd vivado && \
	vivado -mode tcl -nolog -nojournal -source ./build_top.tcl 2>&1 | tee $(LOGFILE)

quartus: verilog
	cd quartus && \
	quartus_sh -t non-project-build.tcl

clean:
	rm -rf $(SHARED_BUILD_DIR) $(WORK_DIR) $(SHARED_VERILOG_DIR) $(DIR_BSV_GENERATED_STUB) $(CONFIG_CACHE_ROOT) .Xil *.jou *.log

.PHONY: verilog vivado clean quartus
.DEFAULT_GOAL := verilog
