# Janky front-end to bring some sanity (?) to the litany of tools and switches
# for working with a k8s cluster. Note that this file exercise core k8s
# commands that's independent of where/how you cluster live.
#
# This file addresses APPPLing the Deployment, Service, Gateway, and VirtualService
#
# Be sure to set your context appropriately for the log monitor.
#
# The intended approach to working with this makefile is to update select
# elements (body, id, IP, port, etc) as you progress through your workflow.
# Where possible, stodout outputs are tee into .out files for later review.
#


# These will be filled in by template processor
CREG=ZZ-CR-ID
REGID=ZZ-REG-ID
JAVA_HOME=ZZ-JAVA-HOME
GAT_DIR=ZZ-GAT-DIR

# Keep all the logs out of main directory
LOG_DIR=logs

KC=kubectl
DK=docker
AWS=aws
IC=istioctl

# Gatling parameters---you should not have to change these
GAT=$(GAT_DIR)/bin/gatling.sh
SIM_DIR=gatling/simulations
SIM_PACKAGE=proj756
SIM_PACKAGE_DIR=$(SIM_DIR)/$(SIM_PACKAGE)
SIM_FILE=ReadTables.scala
SIM_NAME=ReadUserSim
SIM_FULL_NAME=$(SIM_PACKAGE).$(SIM_NAME)
GATLING_OPTIONS=
USERS=1

# these might need to change
APP_NS=c756ns
ISTIO_NS=istio-system

# This is the only entry that *must* be run from k8s-tpl.mak
# (because it creates k8s.mak)
templates:
	tools/process-templates.sh

istio:
	$(IC) install --set profile=demo --set hub=gcr.io/istio-release | tee -a $(LOG_DIR)/mk-reinstate.log

deploy: appns gw s1 s2 db monitoring
	$(KC) -n $(APP_NS) get gw,vs,deploy,svc,pods

appns:
	# Appended "|| true" so that make continues even when command fails
	# because namespace already exists
	$(KC) create ns $(APP_NS) || true
	$(KC) label namespace $(APP_NS) --overwrite=true istio-injection=enabled

monitoring: monvs
	$(KC) -n $(ISTIO_NS) get vs

gw: cluster/service-gateway.yaml
	$(KC) -n $(APP_NS) apply -f $< > $(LOG_DIR)/gw.log

monvs: cluster/monitoring-virtualservice.yaml
	$(KC) -n $(ISTIO_NS) apply -f $< > $(LOG_DIR)/monvs.log

s1: cluster/s1.yaml $(LOG_DIR)/s1.repo.log cluster/s1-sm.yaml
	$(KC) -n $(APP_NS) apply -f $< > $(LOG_DIR)/s1.log
	$(KC) -n $(APP_NS) apply -f cluster/s1-sm.yaml >> $(LOG_DIR)/s1.log

s2: cluster/s2.yaml $(LOG_DIR)/s2.repo.log cluster/s2-sm.yaml
	$(KC) -n $(APP_NS) apply -f $< > $(LOG_DIR)/s2.log
	$(KC) -n $(APP_NS) apply -f cluster/s2-sm.yaml >> $(LOG_DIR)/s2.log

db: cluster/db.yaml $(LOG_DIR)/db.repo.log cluster/db-sm.yaml cluster/awscred.yaml
	$(KC) -n $(APP_NS) apply -f cluster/awscred.yaml > $(LOG_DIR)/db.log
	$(KC) -n $(APP_NS) apply -f $< >> $(LOG_DIR)/db.log
	$(KC) -n $(APP_NS) apply -f cluster/database-vs.yaml >> $(LOG_DIR)/db.log
	$(KC) -n $(APP_NS) apply -f cluster/db-sm.yaml >> $(LOG_DIR)/db.log
	$(KC) -n $(APP_NS) apply -f cluster/dynamodb-service-entry.yaml >> $(LOG_DIR)/db.log

health-off:
	$(KC) -n $(APP_NS) apply -f cluster/s1-nohealth.yaml
	$(KC) -n $(APP_NS) apply -f cluster/s2-nohealth.yaml
	$(KC) -n $(APP_NS) apply -f cluster/db-nohealth.yaml

scratch: clean
	$(KC) delete -n $(APP_NS) deploy cmpt756s1 cmpt756s2 cmpt756db --ignore-not-found=true
	$(KC) delete -n $(APP_NS) svc cmpt756s1 cmpt756s2 cmpt756db --ignore-not-found=true
	$(KC) delete -n $(APP_NS) gw c756-gateway --ignore-not-found=true
	$(KC) delete -n $(APP_NS) vs c756vs --ignore-not-found=true
	$(KC) delete -n $(ISTIO_NS) vs monitoring --ignore-not-found=true
	$(KC) get -n $(APP_NS) deploy,svc,pods,gw,vs
	$(KC) get -n $(ISTIO_NS) vs

clean:
	/bin/rm -f $(LOG_DIR)/{s1,s2,db,gw,monvs}.log

dashboard: showcontext
	echo Please follow instructions at https://docs.aws.amazon.com/eks/latest/userguide/dashboard-tutorial.html
	echo Remember to 'pkill kubectl' when you are done!
	$(KC) proxy &
	open http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/#!/login

extern: showcontext
	$(KC) -n $(ISTIO_NS) get svc istio-ingressgateway

lsa: showcontext
	$(KC) get svc --all-namespaces

# show deploy, pods, vs, and svc of application ns
ls: showcontext
	$(KC) get -n $(APP_NS) gw,vs,svc,deployments,pods

# show containers across all pods
lsd:
	$(KC) get pods --all-namespaces -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort

# Reinstate provisioning on a new set of worker nodes
# Do this after you do `up` on a cluster that implements that operation
reinstate:
	$(KC) create ns $(APP_NS) | tee $(LOG_DIR)/reinstate.log
	$(KC) label ns $(APP_NS) istio-injection=enabled | tee -a $(LOG_DIR)/reinstate.log
	$(IC) install --set profile=demo | tee -a $(LOG_DIR)/reinstate.log

cr:
	$(DK) push $(CREG)/$(REGID)/cmpt756s1:latest | tee $(LOG_DIR)/s1.repo.log
	$(DK) push $(CREG)/$(REGID)/cmpt756s2:latest | tee $(LOG_DIR)/s2.repo.log
	$(DK) push $(CREG)/$(REGID)/cmpt756db:latest | tee $(LOG_DIR)/db.repo.log

# handy bits for the container images... not necessary

image: showcontext
	$(DK) image ls | tee __header | grep $(REGID) > __content
	head -n 1 __header
	cat __content
	rm __content __header
#
# the s1 service
#
$(LOG_DIR)/s1.repo.log: s1/Dockerfile s1/app.py s1/requirements.txt
	$(DK) build -t $(CREG)/$(REGID)/cmpt756s1:latest s1 | tee $(LOG_DIR)/s1.img.log
	$(DK) push $(CREG)/$(REGID)/cmpt756s1:latest | tee $(LOG_DIR)/s1.repo.log

#
# the s2 service
#
$(LOG_DIR)/s2.repo.log: s2/Dockerfile s2/app.py s2/requirements.txt
	$(DK) build -t $(CREG)/$(REGID)/cmpt756s2:latest s2 | tee $(LOG_DIR)/s2.img.log
	$(DK) push $(CREG)/$(REGID)/cmpt756s2:latest | tee $(LOG_DIR)/s2.repo.log

#
# the db service
#
$(LOG_DIR)/db.repo.log: db/Dockerfile db/app.py db/requirements.txt
	$(DK) build -t $(CREG)/$(REGID)/cmpt756db:latest db | tee $(LOG_DIR)/db.img.log
	$(DK) push $(CREG)/$(REGID)/cmpt756db:latest | tee $(LOG_DIR)/db.repo.log

# reminder of current context
showcontext:
	$(KC) config get-contexts

#
# Start the AWS DynamoDB service
#
dynamodb: cluster/cloudformationdynamodb.json
	$(AWS) cloudformation create-stack --stack-name db --template-body file://$<

#
# Login to the container registry
#
registry-login:
	# Use '@' to suppress echoing the $CR_PAT to screen
	@/bin/sh -c 'echo ${CR_PAT} | $(DK) login $(CREG) -u $(REGID) --password-stdin'

#
# Get the URLs for the services
#
# Utility to get the hostname (AWS) or ip (everyone else) of a load-balanced service
# Must be followed by a service
IP_GET_CMD=tools/getip.sh $(KC) $(ISTIO_NS)

# This expression is reused several times
# Use back-tick for subshell so as not to confuse with make $() variable notation
INGRESS_IP=`$(IP_GET_CMD) svc/istio-ingressgateway`

kiali-url:
	@/bin/sh -c 'echo http://$(INGRESS_IP)/kiali'

grafana-url:
	@# Use back-tick for subshell so as not to confuse with make $() variable notation
	@/bin/sh -c 'echo http://`$(IP_GET_CMD) svc/grafana-ingress`:3000/'

prometheus-url:
	@# Use back-tick for subshell so as not to confuse with make $() variable notation
	@/bin/sh -c 'echo http://`$(IP_GET_CMD) svc/prom-ingress`:9090/'

#
# Gatling
#
# Suffix to all Gatling commands
# 2>&1:       Redirect stderr to stdout. This ensures the long errors from a
#             misnamed Gatling script are clipped
# | head -18: Display first 18 lines, discard the rest
# &:          Run in background
GAT_SUFFIX=2>&1 | head -18 &
#
# General Gatling target: Specify CLUSTER_IP, USERS, and SIM_NAME as environment variables. Full output.
gatling: $(SIM_PACKAGE_DIR)/$(SIM_FILE)
	JAVA_HOME=$(JAVA_HOME) $(GAT) -rsf gatling/resources -sf $(SIM_DIR) -bf $(GAT_DIR)/target/test-classes -s $(SIM_FULL_NAME) -rd "Simulation $(SIM_NAME)" $(GATLING_OPTIONS)

# The following should probably not be used---it starts the job but under most shells
# this process will not be listed by the `jobs` command. This makes it difficult
# to kill the process when you want to end the load test
# Shortcut: Read from Music table on current cluster. Only specify USERS.
gatling-music:
	@/bin/sh -c 'CLUSTER_IP=$(INGRESS_IP) USERS=$(USERS) SIM_NAME=ReadMusicSim JAVA_HOME=$(JAVA_HOME) $(GAT) -rsf gatling/resources -sf $(SIM_DIR) -bf $(GAT_DIR)/target/test-classes -s $(SIM_FULL_NAME) -rd "Simulation $(SIM_NAME)" $(GATLING_OPTIONS) $(GAT_SUFFIX)'

# Different approach from gatling-music but the same problems. Probably do not use this.
# Shortcut: Read from User table on current cluster. Only specify USERS.
gatling-user:
	@/bin/sh -c 'CLUSTER_IP=$(INGRESS_IP) USERS=$(USERS) SIM_NAME=ReadUserSim make -e -f k8s.mak gatling $(GAT_SUFFIX)'

# PREFERRED METHOD
# Less convenient than gatling-music or gatling-user but the resulting commands
# are listed by `jobs` and thus easy to kill.
# This merely prints a suggested command that you must then copy into your
# command line and edit, then submit
gatling-command:
	@/bin/sh -c 'echo "CLUSTER_IP=$(INGRESS_IP) USERS=1 SIM_NAME=ReadMusicSim make -e -f k8s.mak gatling $(GAT_SUFFIX)"'

#
# Provision the entire stack
#
# Preconditions:
# 1. Current context is a running Kubernetes cluster (make -f {az,eks,gcp,mk}.mak start)
# 2. Templates have been instantiated (make -f k8s-tpl.mak templates)
#
# THIS IS BETA AND MAY NOT WORK IN ALL CASES
#
provision: istio prom kiali deploy

prom:
	make -f obs.mak init-helm
	make -f obs.mak install-prom

kiali:
	make -f obs.mak install-kiali
	# Kiali operator can take awhile to start Kiali
	tools/waiteq.sh 'app=kiali' '{.items[*]}'              ''        'Kiali' 'Created'
	tools/waitne.sh 'app=kiali' '{.items[0].status.phase}' 'Running' 'Kiali' 'Running'
