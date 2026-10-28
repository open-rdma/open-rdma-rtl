# OpenRDMA-flow 逻辑模块 ID 到物理目录的唯一映射。
_FLOW_MODULES_MK := $(lastword $(MAKEFILE_LIST))
FLOW_ROOT := $(abspath $(dir $(_FLOW_MODULES_MK))/../..)

M0_DIR_NAME := m0_doorbell_analysis
M1_DIR_NAME := m1_dma_engine
M2_DIR_NAME := m2_packet_assembly
M3_DIR_NAME := m3_mrc_tx_scheduler
M4_DIR_NAME := m4_rx_packet_buffer
M5_DIR_NAME := m5_rx_packet_parser
M6_DIR_NAME := m6_rx_rq_bitmap
M7_DIR_NAME := m7_rx_dma_placement
M8_DIR_NAME := m8_rx_ordered_queue
M9_DIR_NAME := m9_retx_state_manager
M10_DIR_NAME := m10_retx_report_engine
M11_DIR_NAME := m11_retx_retry_engine

M0_DIR := $(FLOW_ROOT)/$(M0_DIR_NAME)
M1_DIR := $(FLOW_ROOT)/$(M1_DIR_NAME)
M2_DIR := $(FLOW_ROOT)/$(M2_DIR_NAME)
M3_DIR := $(FLOW_ROOT)/$(M3_DIR_NAME)
M4_DIR := $(FLOW_ROOT)/$(M4_DIR_NAME)
M5_DIR := $(FLOW_ROOT)/$(M5_DIR_NAME)
M6_DIR := $(FLOW_ROOT)/$(M6_DIR_NAME)
M7_DIR := $(FLOW_ROOT)/$(M7_DIR_NAME)
M8_DIR := $(FLOW_ROOT)/$(M8_DIR_NAME)
M9_DIR := $(FLOW_ROOT)/$(M9_DIR_NAME)
M10_DIR := $(FLOW_ROOT)/$(M10_DIR_NAME)
M11_DIR := $(FLOW_ROOT)/$(M11_DIR_NAME)

TX_INTEGRATION_DIR := $(FLOW_ROOT)/integrations/tx
RX_INTEGRATION_DIR := $(FLOW_ROOT)/integrations/rx
RETX_INTEGRATION_DIR := $(FLOW_ROOT)/integrations/retx
E2E_INTEGRATION_DIR := $(FLOW_ROOT)/integrations/e2e
RETX_RUNTIME_DIR := $(FLOW_ROOT)/retx_runtime

SHARED_DIR := $(FLOW_ROOT)/shared
SHARED_MAKE_DIR := $(SHARED_DIR)/make
SHARED_PYTHON := $(SHARED_DIR)/python
SHARED_COMMON_BSV := $(SHARED_DIR)/bsv/common
SHARED_TX_BSV := $(SHARED_DIR)/bsv/tx
SHARED_RX_BSV := $(SHARED_DIR)/bsv/rx
RETX_CONTRACT_DIR := $(SHARED_DIR)/contracts/retx
RETX_GENERATED_DIR := $(SHARED_DIR)/generated/retx
RETX_GENERATED_BSV := $(RETX_GENERATED_DIR)/bsv
RETX_GENERATED_PYTHON := $(RETX_GENERATED_DIR)/python
RETX_GENERATED_TB := $(RETX_GENERATED_DIR)/tb

FLOW_PYTHONPATH := $(SHARED_PYTHON):$(RETX_GENERATED_PYTHON)
