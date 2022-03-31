#!/bin/bash

# Copyright 2018 Istio Authors
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

# Output a message, with a timestamp matching istio log format
function log() {
  echo -e "$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ')\t$*"
}

# Trace runs the provided command and records additional timing information
# NOTE: to avoid spamming the logs, we disable xtrace and re-enable it before executing the function
# and after completion. If xtrace was never set, this will result in xtrace being enabled.
# Ideally we would restore the old xtrace setting, but I don't think its possible to do that without also log-spamming
# If we need to call it from a context without xtrace we can just make a new function.
function trace() {
  { set +x; } 2>/dev/null
  log "Running '${1}'"
  start="$(date -u +%s.%N)"
  { set -x; } 2>/dev/null

  "${@:2}"

  { set +x; } 2>/dev/null
  elapsed=$( date +%s.%N --date="$start seconds ago" )
  log "Command '${1}' complete in ${elapsed}s"
  # Write to YAML file as well for easy reading by tooling
  echo "'${1}': $elapsed" >> "${ARTIFACTS}/trace.yaml"
  { set -x; } 2>/dev/null
}

function setup_gcloud_credentials() {
  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
    if [[ $(command -v gcloud) && -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
      gcloud auth configure-docker -q
      #echo "Not configure gcloud auth configure-docker -q"
    elif [[ $(command -v docker-credential-gcr) ]]; then
      docker-credential-gcr configure-docker
      #echo "Not configure docker-credential-gcr configure-docker"
    else
      echo "No credential helpers found, push to docker may not function properly"
    fi
  fi
}

function setup_and_export_git_sha() {
  if [[ -n "${CI:-}" ]]; then

    if [ -z "${PULL_PULL_SHA:-}" ]; then
      if [ -z "${PULL_BASE_SHA:-}" ]; then
        GIT_SHA="$(git rev-parse --verify HEAD)"
        export GIT_SHA
      else
        export GIT_SHA="${PULL_BASE_SHA}"
      fi
    else
      export GIT_SHA="${PULL_PULL_SHA}"
    fi
  else
    # Use the current commit.
    GIT_SHA="$(git rev-parse --verify HEAD)"
    export GIT_SHA
  fi
  GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  export GIT_BRANCH
  setup_gcloud_credentials
}

# Download and unpack istio release artifacts.
function download_untar_istio_release() {
  local url_path=${1}
  local tag=${2}
  local dir=${3:-.}
  # Download artifacts
  LINUX_DIST_URL="${url_path}/istio-${tag}-linux.tar.gz"

  wget  -q "${LINUX_DIST_URL}" -P "${dir}"
  tar -xzf "${dir}/istio-${tag}-linux.tar.gz" -C "${dir}"
}

function buildx-create() {
  export DOCKER_CLI_EXPERIMENTAL=enabled
    ls -la /home
    ls -la /home/.config    || true
    ls -la /home/.config/gcloud || true
    ls -la /home/.config/gcloud/configurations || true
    ls -la /home/.config/gcloud/configuration/config_default || true
    cat ~/.docker/config.json || true
    whoami || true
    echo "HOME is:"$HOME
    echo "ROOT is:"$ROOT
    env || true
  buildkit_img="gcr.io/istio-testing/buildkit:v0.9.2"
  #[[ "$(uname -m)" == "aarch64" ]] && buildkit_img="moby/buildkit:v0.9.2"
  if ! docker buildx ls | grep -q container-builder; then
    docker buildx create --driver-opt network=host,image=${buildkit_img} --name container-builder --buildkitd-flags="--debug"      
    # Pre-warm the builder. If it fails, fetch logs, but continue
    docker buildx inspect --bootstrap container-builder || docker logs buildx_buildkit_container-builder0 || true
  fi
  docker buildx use container-builder
  echo "Now show docker buildx: XXXXXXXXXXXXXXXXXXXXXXX"
  docker buildx ls
}

function build_images() {
  SELECT_TEST="${1}"

  buildx-create

  # Build just the images needed for tests
  targets="docker.pilot docker.proxyv2 "
  
  if [[ "$(uname -m)" == "aarch64" ]]; then
     echo "TARGETARCH = arm64"
     export TARGETARCH="arm64"
     export TARGET_ARCH=arm64
     export DOCKER_ARCHITECTURES=linux/arm64
  else
     export TARGET_ARCH=amd64
  fi

 # For arm64, we need to build Envoy and install envoy
  if [[ "$(uname -m)" == "aarch64" ]]; then
     echo "Now check image build-tools-proxy:"
     #docker images | grep "build-tools"
     docker images    
     echo "Now copy the envoy arm64 binary to release:"
     mkdir -p out/linux_arm64/release
     tar xvf envoy.tar.gz -C out/linux_arm64/release
     chmod +x out/linux_arm64/release/envoy
     cp out/linux_arm64/release/envoy out/linux_arm64
     #cp out/linux_arm64/release/envoy .
     chmod +w out/linux_arm64/envoy
     pwd
     ls -l out/linux_arm64/envoy
     #echo "TARGET_OUT_LINUX:"${TARGET_OUT_LINUX} || true
     #echo "ISTIO_ENVOY_LINUX_RELEASE_DIR:"${ISTIO_ENVOY_LINUX_RELEASE_DIR} || true
     #ls -l ${ISTIO_ENVOY_LINUX_RELEASE_DIR}  || true
  fi


  # For arm64, we need to build the base image by ourselves
  if [[ "$(uname -m)" == "aarch64" ]]; then
     echo "Now build the base images for arm64 platform: AAAAAAAAAAAAAAAAAAAAAAAAAAA"
     DOCKER_TARGETS='docker.base docker.distroless' \
         HUBS="gcr.io/istio-release" TARGET_ARCH="arm64" make docker
  fi


  # use ubuntu:bionic to test vms by default
  nonDistrolessTargets="docker.app docker.app_sidecar_ubuntu_bionic "
    
  # For arm64, only run docker.app, but bypass all others
  if [[ "$(uname -m)" == "aarch64" ]]; then
     echo "this is aarch64 platform, choose docker.app"
     nonDistrolessTargets="docker.app "
  elif [[ "${SELECT_TEST}" == "test.integration.pilot.kube" ]]; then
    #  if [[ "${SELECT_TEST}" == "test.integration.pilot.kube" &&  ]]; then
    nonDistrolessTargets+="docker.app_sidecar_ubuntu_xenial docker.app_sidecar_ubuntu_focal docker.app_sidecar_ubuntu_bionic "
    nonDistrolessTargets+="docker.app_sidecar_debian_9 docker.app_sidecar_debian_10 docker.app_sidecar_centos_7 docker.app_sidecar_centos_8 "
  fi

  targets+="docker.operator "
  targets+="docker.install-cni "
  
  printdir=`ls -la ~/`
  echo "lib.sh: ttttttttttttt:"
  echo $printdir
  
  echo $(env)
  
  if [[ "${VARIANT:-default}" == "distroless" ]]; then
    echo "Now build the base images distroless for arm64 platform: BBBBBBBBBBBBBBBBBBBBBBBBB"
    if [[ "$(uname -m)" == "aarch64" ]]; then
      DOCKER_BUILD_VARIANTS="distroless" DOCKER_TARGETS="${targets}" TARGET_ARCH=${TARGET_ARCH} make dockerx.pushx
      DOCKER_BUILD_VARIANTS="default" DOCKER_TARGETS="${nonDistrolessTargets}" TARGET_ARCH=${TARGET_ARCH} make dockerx.pushx
    else
      DOCKER_BUILD_VARIANTS="distroless" DOCKER_TARGETS="${targets}" make dockerx.pushx
      DOCKER_BUILD_VARIANTS="default" DOCKER_TARGETS="${nonDistrolessTargets}" make dockerx.pushx
    fi
  else
    echo "Now build the base images for arm64 platform: CCCCCCC"
    if [[ "$(uname -m)" == "aarch64" ]]; then
      DOCKER_BUILD_VARIANTS="${VARIANT:-default}" DOCKER_TARGETS="${targets} ${nonDistrolessTargets}" ISTIO_ENVOY_LOCAL=out/linux_arm64/envoy TARGET_ARCH=${TARGET_ARCH} make dockerx.pushx
    else
      DOCKER_BUILD_VARIANTS="${VARIANT:-default}" DOCKER_TARGETS="${targets} ${nonDistrolessTargets}" make dockerx.pushx
    fi
  fi
}

# Creates a local registry for kind nodes to pull images from. Expects that the "kind" network already exists.
function setup_kind_registry() {
  # create a registry container if it not running already
  running="$(docker inspect -f '{{.State.Running}}' "${KIND_REGISTRY_NAME}" 2>/dev/null || true)"
  registry_img="gcr.io/istio-testing/registry:2"
  [[ "$(uname -m)" == "aarch64" ]] && registry_img="registry:2"
  if [[ "${running}" != 'true' ]]; then
      docker run \
        -d --restart=always -p "${KIND_REGISTRY_PORT}:5000" --name "${KIND_REGISTRY_NAME}" \
        ${registry_img}
    # Allow kind nodes to reach the registry
    docker network connect "kind" "${KIND_REGISTRY_NAME}"
  fi

  # https://docs.tilt.dev/choosing_clusters.html#discovering-the-registry
  for cluster in $(kind get clusters); do
    # TODO get context/config from existing variables
    kind export kubeconfig --name="${cluster}"
    for node in $(kind get nodes --name="${cluster}"); do
      kubectl annotate node "${node}" "kind.x-k8s.io/registry=localhost:${KIND_REGISTRY_PORT}" --overwrite;
    done
  done
}

# setup_cluster_reg is used to set up a cluster registry for multicluster testing
function setup_cluster_reg () {
    MAIN_CONFIG=""
    for context in "${CLUSTERREG_DIR}"/*; do
        if [[ -z "${MAIN_CONFIG}" ]]; then
            MAIN_CONFIG="${context}"
        fi
        export KUBECONFIG="${context}"
        kubectl delete ns istio-system-multi --ignore-not-found
        kubectl delete clusterrolebinding istio-multi-test --ignore-not-found
        kubectl create ns istio-system-multi
        kubectl create sa istio-multi-test -n istio-system-multi
        kubectl create clusterrolebinding istio-multi-test --clusterrole=cluster-admin --serviceaccount=istio-system-multi:istio-multi-test
        CLUSTER_NAME=$(kubectl config view --minify=true -o "jsonpath={.clusters[].name}")
        gen_kubeconf_from_sa istio-multi-test "${context}"
    done
    export KUBECONFIG="${MAIN_CONFIG}"
}

function gen_kubeconf_from_sa () {
    local service_account=$1
    local filename=$2

    SERVER=$(kubectl config view --minify=true -o "jsonpath={.clusters[].cluster.server}")
    SECRET_NAME=$(kubectl get sa "${service_account}" -n istio-system-multi -o jsonpath='{.secrets[].name}')
    CA_DATA=$(kubectl get secret "${SECRET_NAME}" -n istio-system-multi -o "jsonpath={.data['ca\\.crt']}")
    TOKEN=$(kubectl get secret "${SECRET_NAME}" -n istio-system-multi -o "jsonpath={.data['token']}" | base64 --decode)

    cat <<EOF > "${filename}"
      apiVersion: v1
      clusters:
         - cluster:
             certificate-authority-data: ${CA_DATA}
             server: ${SERVER}
           name: ${CLUSTER_NAME}
      contexts:
         - context:
             cluster: ${CLUSTER_NAME}
             user: ${CLUSTER_NAME}
           name: ${CLUSTER_NAME}
      current-context: ${CLUSTER_NAME}
      kind: Config
      preferences: {}
      users:
         - name: ${CLUSTER_NAME}
           user:
             token: ${TOKEN}
EOF
}

# gives a copy of a given topology JSON editing the given key on the entry with the given cluster name
function set_topology_value() {
    local JSON="$1"
    local CLUSTER_NAME="$2"
    local KEY="$3"
    local VALUE="$4"
    VALUE=$(echo "${VALUE}" | awk '{$1=$1};1')

    echo "${JSON}" | jq '(.[] | select(.clusterName =="'"${CLUSTER_NAME}"'") | .'"${KEY}"') |="'"${VALUE}"'"'
}
