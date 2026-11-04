# Optional, so the editor definition targets work without a deployment configuration.
-include config.env
export
.DEFAULT_GOAL := build

ORCA_CONFIGMAP ?= orca-editor-definition
# che-operator ships the dashboard's copy of devfile.yaml. Point this at a che-operator
# checkout's editors-definitions/che-orca-next.yaml to update it in place.
CHE_OPERATOR_DEFINITION ?=
CHE_OPERATOR_DEFINITION_URL := https://raw.githubusercontent.com/eclipse-che/che-operator/main/editors-definitions/che-orca-next.yaml

.PHONY: check-namespace build push devfile register unregister deploy teardown editor-definition check-editor-definition

check-namespace:
	@test -n "$(NAMESPACE)" || { echo "Set NAMESPACE in config.env before registering or removing Orca."; exit 1; }

build:
	podman build --platform linux/amd64 -f Containerfile -t $(ORCA_IMAGE) .

push:
	podman push $(ORCA_IMAGE)

devfile:
	python3 shared/render-devfile.py devfile.yaml --output devfile-rendered.yaml

register: check-namespace devfile
	oc create configmap $(ORCA_CONFIGMAP) \
	  --from-file=devfile-rendered.yaml \
	  -n $(NAMESPACE)
	oc label configmap $(ORCA_CONFIGMAP) \
	  app.kubernetes.io/part-of=che.eclipse.org \
	  app.kubernetes.io/component=editor-definition \
	  -n $(NAMESPACE)
	@rm -f devfile-rendered.yaml

unregister: check-namespace
	oc delete configmap $(ORCA_CONFIGMAP) -n $(NAMESPACE)

# Prints che-operator's definition rendered from devfile.yaml, or updates CHE_OPERATOR_DEFINITION.
editor-definition:
ifeq ($(CHE_OPERATOR_DEFINITION),)
	@curl -fsSL $(CHE_OPERATOR_DEFINITION_URL) | python3 shared/render-devfile.py devfile.yaml --che-operator /dev/stdin
else
	python3 shared/render-devfile.py devfile.yaml --che-operator $(CHE_OPERATOR_DEFINITION) --output $(CHE_OPERATOR_DEFINITION)
endif

# Fails when che-operator's definition on main differs from devfile.yaml.
check-editor-definition:
	@curl -fsSL $(CHE_OPERATOR_DEFINITION_URL) | python3 shared/render-devfile.py devfile.yaml --che-operator /dev/stdin --check

deploy:
	./deploy.sh

teardown:
	./teardown.sh
