.PHONY: wiki serve nc-app-deploy nc-app-pin nc-app-status help

wiki: ## Build the wiki into infra/nginx/html/wiki
	python3 tools/build_wiki.py

serve: ## Preview the site locally at http://localhost:8080
	cd infra/nginx/html && python3 -m http.server 8080

nc-app-deploy: ## Install/update the pinned byebyemoneylist release in Nextcloud AIO
	bash infra/nextcloud/deploy-app.sh

nc-app-pin: ## Fetch the release sha256 into infra/nextcloud/versions.env
	bash infra/nextcloud/deploy-app.sh --pin

nc-app-status: ## Show byebyemoneylist app + migration status in Nextcloud AIO
	docker exec -u www-data nextcloud-aio-nextcloud php occ app:list | grep -i byebyemoneylist || true
	docker exec -u www-data nextcloud-aio-nextcloud php occ migrations:status byebyemoneylist

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'
