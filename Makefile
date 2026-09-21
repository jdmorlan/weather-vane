# Vane — shortcuts you run from the repo root.
#
# `make` on its own lists what's here. Everything below cd's into the right
# subdirectory itself, so you never have to.

ANALYSIS := analysis
NOTEBOOK := notebooks/00-one-day.ipynb

.DEFAULT_GOAL := help
.PHONY: help notebook lab sync clean-cache

help: ## List the targets
	@echo "Vane"
	@echo
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo

notebook: | uv-installed ## Open the weather data notebook
	cd $(ANALYSIS) && uv run jupyter lab $(NOTEBOOK)

lab: | uv-installed ## Open JupyterLab at the notebook list
	cd $(ANALYSIS) && uv run jupyter lab

sync: | uv-installed ## Install or update the Python environment
	cd $(ANALYSIS) && uv sync

clean-cache: ## Delete the Parquet cache; it rebuilds from the NDJSON on next read
	rm -rf $(ANALYSIS)/cache
	@echo "Cache cleared. The next samples() call rebuilds it (~10s)."

# A missing `uv` is the one failure here with a non-obvious fix, so say the fix
# rather than letting make print "command not found" and stop.
.PHONY: uv-installed
uv-installed:
	@command -v uv >/dev/null || { \
		echo "uv isn't installed. Get it with:"; \
		echo "    brew install uv"; \
		exit 1; }
