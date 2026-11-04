include config.env
export
.DEFAULT_GOAL := build

ORCA_CONFIGMAP ?= orca-editor-definition
# The editor definition lives only in che-operator. Point this at a che-operator
# checkout's editors-definitions/che-orca-next.yaml to test a change to it.
CHE_OPERATOR_DEFINITION ?=
CHE_OPERATOR_DEFINITION_URL := https://raw.githubusercontent.com/eclipse-che/che-operator/main/editors-definitions/che-orca-next.yaml

.PHONY: check-namespace build push devfile register unregister deploy teardown

check-namespace:
	@test -n "$(NAMESPACE)" || { echo "Set NAMESPACE in config.env before registering or removing Orca."; exit 1; }

build:
	podman build --platform linux/amd64 -f Containerfile -t $(ORCA_IMAGE) .

push:
	podman push $(ORCA_IMAGE)

devfile:
ifeq ($(CHE_OPERATOR_DEFINITION),)
	curl -fsSL $(CHE_OPERATOR_DEFINITION_URL) | python3 shared/render-devfile.py /dev/stdin --output devfile-rendered.yaml
else
	python3 shared/render-devfile.py $(CHE_OPERATOR_DEFINITION) --output devfile-rendered.yaml
endif

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

deploy:
	./deploy.sh

teardown:
	./teardown.sh
