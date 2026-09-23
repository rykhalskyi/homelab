.PHONY: wiki serve nc-app-deploy nc-app-pin nc-app-status laya-api-deploy laya-api-pin laya-api-status help

wiki: ## Build the wiki into infra/nginx/html/wiki
	python3 tools/build_wiki.py

serve: ## Preview the site locally at http://localhost:8080
	cd infra/nginx/html && python3 -m http.server 8080

nc-app-deploy: ## Install/update the pinned byebyemoneylist release in Nextcloud AIO
	bash infra/nextcloud/deploy-app.sh

nc-app-pin: ## Pin version + sha256 (VERSION=x.y.z to override) into versions.env
	bash infra/nextcloud/deploy-app.sh --pin $(if $(VERSION),--version $(VERSION),)

nc-app-status: ## Show byebyemoneylist app + installed version in Nextcloud AIO
	docker exec -u www-data nextcloud-aio-nextcloud php occ app:list | grep -i byebyemoneylist || true
	docker exec -u www-data nextcloud-aio-nextcloud php occ config:app:get byebyemoneylist installed_version

laya-api-deploy: ## Deploy/update the pinned laya-api image on node-one
	bash infra/laya-api/deploy.sh

laya-api-pin: ## Pin laya-api version + digest (VERSION=x.y.z to override) into versions.env
	bash infra/laya-api/deploy.sh --pin $(if $(VERSION),--version $(VERSION),)

laya-api-status: ## Show the laya-api container status
	docker ps --filter name=laya-api --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'
