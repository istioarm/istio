#!/bin/bash

# WARNING: DO NOT EDIT, THIS FILE IS PROBABLY A COPY
#
# The original version of this file is located in the https://github.com/istio/common-files repo.
# If you're looking at this file in a different repo and want to make a change, please go to the
# common-files repo, make the change there and check it in. Then come back to this repo and run
# "make update-common".

# Copyright Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e
set -x

# The purpose of this file is to unify prow/lib.sh in both istio and istio.io
# repos to avoid code duplication.

####################################################################
#################   COMMON SECTION   ###############################
####################################################################

# DEFAULT_KIND_IMAGE is used to set the Kubernetes version for KinD unless overridden in params to setup_kind_cluster(s)
DEFAULT_KIND_IMAGE="gcr.io/istio-testing/kindest/node:v1.19.1"

if [[ "$(uname -m)" == "aarch64" ]]; then
        echo "this is aarch64 platform, uses kindest/node:v1.19.11"
        DEFAULT_KIND_IMAGE="kindest/node:v1.19.11"
fi


# COMMON_SCRIPTS contains the directory this file is in.
COMMON_SCRIPTS=$(dirname "${BASH_SOURCE:-$0}")

# load_cluster_topology function reads cluster configuration topology file and
# sets up environment variables used by other functions. So this should be called
# before anything else.
#
# Note: Cluster configuration topology file specifies basic configuration of each
# KinD cluster like its name, pod and service subnets and network_id. If two cluster
# have the same network_id then they belong to the same network and their pods can
# talk to each other directly.
#
# [{ "cluster_name": "cluster1","pod_subnet": "10.10.0.0/16","svc_subnet": "10.255.10.0/24","network_id": "0" },
#  { "cluster_name": "cluster2","pod_subnet": "10.20.0.0/16","svc_subnet": "10.255.20.0/24","network_id": "0" },
#  { "cluster_name": "cluster3","pod_subnet": "10.30.0.0/16","svc_subnet": "10.255.30.0/24","network_id": "1" }]
function load_cluster_topology() {
  CLUSTER_TOPOLOGY_CONFIG_FILE="${1}"

  if [[ ! -f "${CLUSTER_TOPOLOGY_CONFIG_FILE}" ]]; then
    echo 'cluster topology configuration file is not specified'
    exit 1
  fi

  export CLUSTER_NAMES
  export CLUSTER_POD_SUBNETS
  export CLUSTER_SVC_SUBNETS
  export CLUSTER_NETWORK_ID

  KUBE_CLUSTERS=$(jq '.[] | select(.kind == "Kubernetes" or .kind == null)' "${CLUSTER_TOPOLOGY_CONFIG_FILE}")

  while read -r value; do
    CLUSTER_NAMES+=("$value")
  done < <(echo "${KUBE_CLUSTERS}" | jq -r '.cluster_name // .clusterName')

  while read -r value; do
    CLUSTER_POD_SUBNETS+=("$value")
  done < <(echo "${KUBE_CLUSTERS}" | jq -r '.pod_subnet // .podSubnet')

  while read -r value; do
    CLUSTER_SVC_SUBNETS+=("$value")
  done < <(echo "${KUBE_CLUSTERS}" | jq -r '.svc_subnet // .svcSubnet')

  while read -r value; do
    CLUSTER_NETWORK_ID+=("$value")
  done < <(echo "${KUBE_CLUSTERS}" | jq -r '.network_id // .network')

  export NUM_CLUSTERS
  NUM_CLUSTERS=$(echo "${KUBE_CLUSTERS}" | jq -s 'length')

  echo "${CLUSTER_NAMES[@]}"
  echo "${CLUSTER_POD_SUBNETS[@]}"
  echo "${CLUSTER_SVC_SUBNETS[@]}"
  echo "${CLUSTER_NETWORK_ID[@]}"
  echo "${NUM_CLUSTERS}"
}

#####################################################################
###################   SINGLE-CLUSTER SECTION   ######################
#####################################################################

# cleanup_kind_cluster takes a single parameter NAME
# and deletes the KinD cluster with that name
function cleanup_kind_cluster() {
  echo "Test exited with exit code $?."
  NAME="${1}"
  kind export logs --name "${NAME}" "${ARTIFACTS}/kind" -v9 || true
  if [[ -z "${SKIP_CLEANUP:-}" ]]; then
    echo "Cleaning up kind cluster"
    kind delete cluster --name "${NAME}" -v9 || true
  fi
}

# check_default_cluster_yaml checks the presence of default cluster YAML
# It returns 1 if it is not present
function check_default_cluster_yaml() {
  if [[ -z "${DEFAULT_CLUSTER_YAML}" ]]; then
    echo 'DEFAULT_CLUSTER_YAML file must be specified. Exiting...'
    return 1
  fi
}

# setup_kind_cluster creates new KinD cluster with given name, image and configuration
# 1. NAME: Name of the Kind cluster (optional)
# 2. IMAGE: Node image used by KinD (optional)
# 3. CONFIG: KinD cluster configuration YAML file. If not specified then DEFAULT_CLUSTER_YAML is used
# 4. NOMETALBINSTALL: Dont install matllb if set.
# This function returns 0 when everything goes well, or 1 otherwise
# If Kind cluster was already created then it would be cleaned up in case of errors
function setup_kind_cluster() {
  NAME="${1:-istio-testing}"
  IMAGE="${2:-"${DEFAULT_KIND_IMAGE}"}"
  CONFIG="${3:-}"
  NOMETALBINSTALL="${4:-}"

  check_default_cluster_yaml

  # Delete any previous KinD cluster
  echo "Deleting previous KinD cluster with name=${NAME}"
  if ! (kind delete cluster --name="${NAME}" -v9) > /dev/null; then
    echo "No existing kind cluster with name ${NAME}. Continue..."
  fi

  # explicitly disable shellcheck since we actually want $NAME to expand now
  # shellcheck disable=SC2064
  trap "cleanup_kind_cluster ${NAME}" EXIT

    # If config not explicitly set, then use defaults
  if [[ -z "${CONFIG}" ]]; then
    # Kubernetes 1.15+
    CONFIG=${DEFAULT_CLUSTER_YAML}
    # Configure the cluster IP Family only for default configs
    if [ "${IP_FAMILY}" = "ipv6" ]; then
      grep 'ipFamily: ipv6' "${CONFIG}" || \
      cat <<EOF >> "${CONFIG}"
networking:
  ipFamily: ipv6
EOF
    fi
  fi

  # Create KinD cluster
  if ! (kind create cluster --name="${NAME}" --config "${CONFIG}" -v9 --retain --image "${IMAGE}" --wait=180s); then
    echo "Could not setup KinD environment. Something wrong with KinD setup. Exporting logs."
    exit 1
  fi

  # If metrics server configuration directory is specified then deploy in
  # the cluster just created
  if [[ -n ${METRICS_SERVER_CONFIG_DIR} ]]; then
    kubectl apply -f "${METRICS_SERVER_CONFIG_DIR}"
  fi

  # Install Metallb if not set to install explicitly
  if [[ -z "${NOMETALBINSTALL}" ]]; then
    install_metallb ""
  fi

  # IPv6 clusters need some CoreDNS changes in order to work in CI:
  # Istio CI doesn't offer IPv6 connectivity, so CoreDNS should be configured
  # to work in an offline environment:
  # https://github.com/coredns/coredns/issues/2494#issuecomment-457215452
  # CoreDNS should handle those domains and answer with NXDOMAIN instead of SERVFAIL
  # otherwise pods stops trying to resolve the domain.
  if [ "${IP_FAMILY}" = "ipv6" ]; then
      # Get the current config
      original_coredns=$(kubectl get -oyaml -n=kube-system configmap/coredns)
      echo "Original CoreDNS config:"
      echo "${original_coredns}"
      # Patch it
      fixed_coredns=$(
        printf '%s' "${original_coredns}" | sed \
          -e 's/^.*kubernetes cluster\.local/& internal/' \
          -e '/^.*upstream$/d' \
          -e '/^.*fallthrough.*$/d' \
          -e '/^.*forward . \/etc\/resolv.conf$/d' \
          -e '/^.*loop$/d' \
      )
      echo "Patched CoreDNS config:"
      echo "${fixed_coredns}"
      printf '%s' "${fixed_coredns}" | kubectl apply -f -
    fi
}

###############################################################################
####################    MULTICLUSTER SECTION    ###############################
###############################################################################

# Cleans up the clusters created by setup_kind_clusters
# It expects CLUSTER_NAMES to be present which means that
# load_cluster_topology must be called before invoking it
function cleanup_kind_clusters() {
  echo "Test exited with exit code $?."
  for c in "${CLUSTER_NAMES[@]}"; do
    cleanup_kind_cluster "${c}"
  done
}

# setup_kind_clusters sets up a given number of kind clusters with given topology
# as specified in cluster topology configuration file.
# 1. IMAGE = docker image used as node by KinD
# 2. IP_FAMILY = either ipv4 or ipv6
#
# NOTE: Please call load_cluster_topology before calling this method as it expects
# cluster topology information to be loaded in advance
function setup_kind_clusters() {
  IMAGE="${1:-"${DEFAULT_KIND_IMAGE}"}"
  KUBECONFIG_DIR="${ARTIFACTS:-$(mktemp -d)}/kubeconfig"
  IP_FAMILY="${2:-ipv4}"

  check_default_cluster_yaml

  # Trap replaces any previous trap's, so we need to explicitly cleanup both clusters here
  trap cleanup_kind_clusters EXIT

  function deploy_kind() {
    IDX="${1}"
    CLUSTER_NAME="${CLUSTER_NAMES[$IDX]}"
    CLUSTER_POD_SUBNET="${CLUSTER_POD_SUBNETS[$IDX]}"
    CLUSTER_SVC_SUBNET="${CLUSTER_SVC_SUBNETS[$IDX]}"
    CLUSTER_YAML="${ARTIFACTS}/config-${CLUSTER_NAME}.yaml"
    if [ ! -f "${CLUSTER_YAML}" ]; then
      cp "${DEFAULT_CLUSTER_YAML}" "${CLUSTER_YAML}"
      cat <<EOF >> "${CLUSTER_YAML}"
networking:
  podSubnet: ${CLUSTER_POD_SUBNET}
  serviceSubnet: ${CLUSTER_SVC_SUBNET}
EOF
    fi

    CLUSTER_KUBECONFIG="${KUBECONFIG_DIR}/${CLUSTER_NAME}"

    # Create the clusters.
    KUBECONFIG="${CLUSTER_KUBECONFIG}" setup_kind_cluster "${CLUSTER_NAME}" "${IMAGE}" "${CLUSTER_YAML}" "true"

    # Kind currently supports getting a kubeconfig for internal or external usage. To simplify our tests,
    # its much simpler if we have a single kubeconfig that can be used internally and externally.
    # To do this, we can replace the server with the IP address of the docker container
    # https://github.com/kubernetes-sigs/kind/issues/1558 tracks this upstream
    CONTAINER_IP=$(docker inspect "${CLUSTER_NAME}-control-plane" --format "{{ .NetworkSettings.Networks.kind.IPAddress }}")
    kind get kubeconfig --name "${CLUSTER_NAME}" --internal | \
      sed "s/${CLUSTER_NAME}-control-plane/${CONTAINER_IP}/g" > "${CLUSTER_KUBECONFIG}"
    if [ ! -s "${CLUSTER_KUBECONFIG}" ]; then
      # TODO(https://github.com/istio/istio/issues/33096) remove this retry
      echo "FAIL: unable to get kubeconfig on first try, trying again"
      sleep 10
      # Output for debugging
      kind get kubeconfig --name "${CLUSTER_NAME}" --internal
      kind get kubeconfig --name "${CLUSTER_NAME}" --internal | \
        sed "s/${CLUSTER_NAME}-control-plane/${CONTAINER_IP}/g" > "${CLUSTER_KUBECONFIG}"
    fi

    # Enable core dumps
    docker exec "${CLUSTER_NAME}"-control-plane bash -c "sysctl -w kernel.core_pattern=/var/lib/istio/data/core.proxy && ulimit -c unlimited"
  }

  # Now deploy the specified number of KinD clusters and
  # wait till they are provisioned successfully.
  declare -a DEPLOY_KIND_JOBS
  for i in "${!CLUSTER_NAMES[@]}"; do
    deploy_kind "${i}" & DEPLOY_KIND_JOBS+=("${!}")
  done

  for pid in "${DEPLOY_KIND_JOBS[@]}"; do
    wait "${pid}" || exit 1
  done

  # Install MetalLB for LoadBalancer support. Must be done synchronously since METALLB_IPS is shared.
  # and keep track of the list of Kubeconfig files that will be exported later
  export KUBECONFIGS
  for CLUSTER_NAME in "${CLUSTER_NAMES[@]}"; do
    KUBECONFIG_FILE="${KUBECONFIG_DIR}/${CLUSTER_NAME}"
    if [[ ${NUM_CLUSTERS} -gt 1 ]]; then
      install_metallb "${KUBECONFIG_FILE}"
    fi
    KUBECONFIGS+=("${KUBECONFIG_FILE}")
  done

  ITER_END=$((NUM_CLUSTERS-1))
  for i in $(seq 0 "$ITER_END"); do
    for j in $(seq 0 "$ITER_END"); do
      if [[ "${j}" -gt "${i}" ]]; then
        NETWORK_ID_I="${CLUSTER_NETWORK_ID[i]}"
        NETWORK_ID_J="${CLUSTER_NETWORK_ID[j]}"
        if [[ "$NETWORK_ID_I" == "$NETWORK_ID_J" ]]; then
          POD_TO_POD_AND_SERVICE_CONNECTIVITY=1
        else
          POD_TO_POD_AND_SERVICE_CONNECTIVITY=0
        fi
        connect_kind_clusters \
          "${CLUSTER_NAMES[i]}" "${KUBECONFIGS[i]}" \
          "${CLUSTER_NAMES[j]}" "${KUBECONFIGS[j]}" \
          "${POD_TO_POD_AND_SERVICE_CONNECTIVITY}"
      fi
    done
  done
}

function connect_kind_clusters() {
  C1="${1}"
  C1_KUBECONFIG="${2}"
  C2="${3}"
  C2_KUBECONFIG="${4}"
  POD_TO_POD_AND_SERVICE_CONNECTIVITY="${5}"

  C1_NODE="${C1}-control-plane"
  C2_NODE="${C2}-control-plane"
  C1_DOCKER_IP=$(docker inspect -f "{{ .NetworkSettings.Networks.kind.IPAddress }}" "${C1_NODE}")
  C2_DOCKER_IP=$(docker inspect -f "{{ .NetworkSettings.Networks.kind.IPAddress }}" "${C2_NODE}")
  if [ "${POD_TO_POD_AND_SERVICE_CONNECTIVITY}" -eq 1 ]; then
    # Set up routing rules for inter-cluster direct pod to pod & service communication
    C1_POD_CIDR=$(KUBECONFIG="${C1_KUBECONFIG}" kubectl get node -ojsonpath='{.items[0].spec.podCIDR}')
    C2_POD_CIDR=$(KUBECONFIG="${C2_KUBECONFIG}" kubectl get node -ojsonpath='{.items[0].spec.podCIDR}')
    C1_SVC_CIDR=$(KUBECONFIG="${C1_KUBECONFIG}" kubectl cluster-info dump | sed -n 's/^.*--service-cluster-ip-range=\([^"]*\).*$/\1/p' | head -n 1)
    C2_SVC_CIDR=$(KUBECONFIG="${C2_KUBECONFIG}" kubectl cluster-info dump | sed -n 's/^.*--service-cluster-ip-range=\([^"]*\).*$/\1/p' | head -n 1)
    docker exec "${C1_NODE}" ip route add "${C2_POD_CIDR}" via "${C2_DOCKER_IP}"
    docker exec "${C1_NODE}" ip route add "${C2_SVC_CIDR}" via "${C2_DOCKER_IP}"
    docker exec "${C2_NODE}" ip route add "${C1_POD_CIDR}" via "${C1_DOCKER_IP}"
    docker exec "${C2_NODE}" ip route add "${C1_SVC_CIDR}" via "${C1_DOCKER_IP}"
  fi
}

function install_metallb() {
  KUBECONFIG="${1}"
  kubectl apply --kubeconfig="$KUBECONFIG" -f "${COMMON_SCRIPTS}/metallb.yaml"
  kubectl create --kubeconfig="$KUBECONFIG" secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"

  if [ -z "${METALLB_IPS4[*]}" ]; then
    # Take IPs from the end of the docker kind network subnet to use for MetalLB IPs
    DOCKER_KIND_SUBNET="$(docker inspect kind | jq '.[0].IPAM.Config[0].Subnet' -r)"
    METALLB_IPS4=()
    while read -r ip; do
      METALLB_IPS4+=("$ip")
    done < <(cidr_to_ips "$DOCKER_KIND_SUBNET" | tail -n 100)
    METALLB_IPS6=()
    if [[ "$(docker inspect kind | jq '.[0].IPAM.Config | length' -r)" == 2 ]]; then
      # Two configs? Must be dual stack.
      DOCKER_KIND_SUBNET="$(docker inspect kind | jq '.[0].IPAM.Config[1].Subnet' -r)"
      while read -r ip; do
        METALLB_IPS6+=("$ip")
      done < <(cidr_to_ips "$DOCKER_KIND_SUBNET" | tail -n 100)
    fi
  fi

  # Give this cluster of those IPs
  RANGE="["
  for i in {0..9}; do
    RANGE+="${METALLB_IPS4[1]},"
    METALLB_IPS4=("${METALLB_IPS4[@]:1}")
    if [[ "${#METALLB_IPS6[@]}" != 0 ]]; then
      RANGE+="${METALLB_IPS6[1]},"
      METALLB_IPS6=("${METALLB_IPS6[@]:1}")
    fi
  done
  RANGE="${RANGE%?}]"

  echo 'apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses: '"$RANGE" | kubectl apply --kubeconfig="$KUBECONFIG" -f -
}

function cidr_to_ips() {
    CIDR="$1"
    # cidr_to_ips returns a list of single IPs from a CIDR. We skip 1000 (since they are likely to be allocated
    # already to other services), then pick the next 100.
    python3 - <<EOF
from ipaddress import ip_network;
from itertools import islice;
[print(str(ip) + "/" + str(ip.max_prefixlen)) for ip in islice(ip_network('$CIDR').hosts(), 1000, 1100)]
EOF
}

function ips_to_cidrs() {
  IP_RANGE_START="$1"
  IP_RANGE_END="$2"
  python3 - <<EOF
from ipaddress import summarize_address_range, IPv4Address
[ print(n.compressed) for n in summarize_address_range(IPv4Address(u'$IP_RANGE_START'), IPv4Address(u'$IP_RANGE_END')) ]
EOF
}
