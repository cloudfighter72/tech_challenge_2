# Convenience targets. Every one of these is a command from PLAN.md.
REGION       ?= us-east-2
CLUSTER      ?= tc2-eks
NAMESPACE    ?= hello-world
RELEASE      ?= hello-world
ACCOUNT      := $(shell aws sts get-caller-identity --query Account --output text)
REGISTRY     := $(ACCOUNT).dkr.ecr.$(REGION).amazonaws.com
IMAGE        := $(REGISTRY)/hello-world
TAG          ?= manual-1

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

## ---- local ----
run-local: ## Run the app in Docker on :8080
	docker build -t hello-world:local ./app
	docker run --rm -p 8080:8080 hello-world:local

## ---- infra ----
tf-init: ## terraform init
	cd terraform && terraform init

tf-plan: ## terraform plan
	cd terraform && terraform plan -out=tfplan

tf-apply: ## terraform apply
	cd terraform && terraform apply tfplan

ecr-only: ## Create just the ECR repo (Phase 4)
	cd terraform && terraform apply -target=aws_ecr_repository.app

kubeconfig: ## Point kubectl at the cluster
	aws eks update-kubeconfig --name $(CLUSTER) --region $(REGION)

## ---- app ----
push: ## Build and push an image manually (TAG=... to override)
	aws ecr get-login-password --region $(REGION) | \
	  docker login --username AWS --password-stdin $(REGISTRY)
	docker build -t $(IMAGE):$(TAG) ./app
	docker push $(IMAGE):$(TAG)

deploy: ## helm upgrade --install
	helm upgrade --install $(RELEASE) ./helm/hello-world \
	  -n $(NAMESPACE) --create-namespace \
	  --set image.repository=$(IMAGE) --set image.tag=$(TAG) --wait

url: ## Print the live ALB URL
	@echo "http://$$(kubectl get ingress $(RELEASE) -n $(NAMESPACE) \
	  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

status: ## Everything at a glance
	kubectl get pods -o wide -n $(NAMESPACE)
	kubectl get svc,ingress,hpa -n $(NAMESPACE)
	kubectl get nodes

## ---- scaling demo ----
load: ## Start the load generator (Phase 8)
	kubectl apply -f k8s/loadtest.yaml

unload: ## Stop it and watch scale-down
	kubectl delete -f k8s/loadtest.yaml

watch: ## Live HPA + node view (portable - no watch(1) needed)
	@while true; do \
	  clear; date; echo; \
	  kubectl get hpa -n $(NAMESPACE); echo; \
	  kubectl get pods -o wide -n $(NAMESPACE); echo; \
	  kubectl get nodes; \
	  sleep 5; \
	done

## ---- teardown ----
destroy: ## Remove the ALB first, then everything else
	-helm uninstall $(RELEASE) -n $(NAMESPACE)
	sleep 30
	cd terraform && terraform destroy
