.PHONY: wiki serve help

wiki: ## Build the wiki into infra/nginx/html/wiki
	python3 tools/build_wiki.py

serve: ## Preview the site locally at http://localhost:8080
	cd infra/nginx/html && python3 -m http.server 8080

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'
