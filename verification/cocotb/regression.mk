#-----------------------------------------------------------------------------
# regression.mk — generic cocotb regression engine (include fragment)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Promoted from nanosoc-multicore-system/cocotb/Makefile so every nanosoc system
# shares one regression driver. The consuming system sets ENVS (the list of
# per-env subdirectories, each a cocotb Makefile) and includes this file:
#
#     ENVS = soc_smoke soc_boot ...
#     # optional: a pre-flight target run before the regression body
#     REGRESSION_PREFLIGHT = check-firmware-clock
#     check-firmware-clock: ; @bash ../scripts/check_firmware_clock.sh $(CMAKE_PRESET)
#     include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/verification/cocotb/regression.mk
#
# Targets: <env> (run one), regression (run all + summary), coverage[,_merge], clean.
#
# Design note: pass/fail is read from cocotb's authoritative per-env results.xml
# (<failure> present => FAIL, file missing => NO-RESULTS), never an intermediate
# shell sentinel — those went missing under concurrent cmake rebuilds / fs races
# and produced false FAILs. Regression iterates envs in a single shell recipe so
# the summary sees exactly the state each env just wrote.
#-----------------------------------------------------------------------------

ifndef ENVS
$(error regression.mk: set ENVS (space-separated cocotb env subdirs) before include)
endif

# Optional pre-flight target run before the regression body (empty = none).
REGRESSION_PREFLIGHT ?=

# Preset the per-env Makefiles build firmware against (forwarded to any preflight).
CMAKE_PRESET ?= gcc-m0plus-le

# Per-env "run" recipe — standalone (`make <env>`) and inlined by regression.
# Exit 0 on PASS, 1 otherwise; decided from results.xml.
define run_env
.PHONY: $(1)
$(1):
	@echo "========================================"
	@echo " Running: $(1)"
	@echo "========================================"
	@$$(MAKE) -C $(1) clean > /dev/null 2>&1 || true
	@rm -f $(1)/results.xml $(1)/run.log
	@$$(MAKE) -C $(1) 2>&1 | tee $(1)/run.log | grep -E '^\*\*|regression' || true
	@if [ ! -f $(1)/results.xml ]; then \
	    echo "  >> $(1): NO-RESULTS (sim did not produce results.xml)"; \
	    exit 1; \
	elif grep -q '<failure' $(1)/results.xml; then \
	    echo "  >> $(1): FAIL"; \
	    exit 1; \
	else \
	    echo "  >> $(1): PASS"; \
	fi
	@echo ""
endef

$(foreach env,$(ENVS),$(eval $(call run_env,$(env))))

# ── Regression target ────────────────────────────────────────────────────────
# Single shell recipe (not phony deps): deterministic order, no -j interleave,
# summary reads the results.xml each env just wrote.
.PHONY: regression
regression: $(REGRESSION_PREFLIGHT)
	@pass=0; fail=0; missing=0; \
	for env in $(ENVS); do \
	    echo "========================================"; \
	    echo " Running: $$env"; \
	    echo "========================================"; \
	    $(MAKE) -C $$env clean > /dev/null 2>&1 || true; \
	    rm -f $$env/results.xml $$env/run.log; \
	    $(MAKE) -C $$env 2>&1 | tee $$env/run.log | grep -E '^\*\*|regression' || true; \
	    if [ ! -f $$env/results.xml ]; then \
	        echo "  >> $$env: NO-RESULTS"; \
	        missing=$$((missing + 1)); \
	    elif grep -q '<failure' $$env/results.xml; then \
	        echo "  >> $$env: FAIL"; \
	        fail=$$((fail + 1)); \
	    else \
	        echo "  >> $$env: PASS"; \
	        pass=$$((pass + 1)); \
	    fi; \
	    echo ""; \
	done; \
	echo "========================================"; \
	echo " Regression Summary"; \
	echo "========================================"; \
	for env in $(ENVS); do \
	    if [ ! -f $$env/results.xml ]; then \
	        status="NO-RESULTS"; \
	    elif grep -q '<failure' $$env/results.xml; then \
	        status="FAIL"; \
	    else \
	        status="PASS"; \
	    fi; \
	    printf "  %-30s %s\n" "$$env" "$$status"; \
	done; \
	echo "----------------------------------------"; \
	printf "  PASS=%d  FAIL=%d  NO-RESULTS=%d  TOTAL=%d\n" \
	    $$pass $$fail $$missing $$((pass + fail + missing)); \
	echo "========================================"; \
	[ "$$fail" -eq 0 ] && [ "$$missing" -eq 0 ]

# ── Coverage regression ──────────────────────────────────────────────────────
#   make coverage [CM_METRICS=line+cond]
CM_METRICS ?= line+cond+fsm+tgl+branch
COV_REPORT  = coverage_report

.PHONY: coverage coverage_merge
coverage: export COVERAGE=1
coverage: export CM_METRICS:=$(CM_METRICS)
coverage: regression coverage_merge

coverage_merge:
	@echo "========================================"
	@echo " Merging coverage databases"
	@echo "========================================"
	@echo "── Per-environment reports ──"
	@for env in $(ENVS); do \
	  urg -full64 -dir $$env/sim_build/simv.vdb -dir $$env/coverage.vdb \
	    -report $(COV_REPORT)/$$env -format both 2>&1 \
	    | grep -E 'Note|Error' || true; \
	done
	@echo ""
	@echo "── Per-environment coverage summary ──"
	@printf "  %-25s %6s %6s %6s %6s %6s %6s\n" "ENVIRONMENT" "SCORE" "LINE" "COND" "TOGGLE" "FSM" "BRANCH"
	@printf "  %-25s %6s %6s %6s %6s %6s %6s\n" "-------------------------" "------" "------" "------" "------" "------" "------"
	@for env in $(ENVS); do \
	  scores=$$(grep -A2 'Total Coverage Summary' $(COV_REPORT)/$$env/dashboard.txt 2>/dev/null \
	    | tail -1 | sed 's/--/  N\/A /g'); \
	  printf "  %-25s %s\n" "$$env" "$$scores"; \
	done
	@echo ""
	@echo "Coverage reports: $(COV_REPORT)/<env>/dashboard.html"

# ── Clean ────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	@for env in $(ENVS); do \
	  $(MAKE) -C $$env clean > /dev/null 2>&1 || true; \
	  rm -rf $$env/sim_build $$env/simv.daidir $$env/__pycache__ $$env/csrc \
	         $$env/coverage.vdb $$env/verdiLog; \
	  rm -f  $$env/run.log $$env/results.xml $$env/.result $$env/ucli.key \
	         $$env/waves.vcd $$env/novas.* $$env/novas_dump.log; \
	done
	@rm -rf merged_coverage.vdb $(COV_REPORT)
	@echo "All environments cleaned"
