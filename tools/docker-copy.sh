#!/bin/bash

# Copyright 2019 Istio Authors
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

INPUTS=("${@}")
TARGET_ARCH=${TARGET_ARCH:-amd64}
DOCKER_WORKING_DIR=${INPUTS[${#INPUTS[@]}-1]}
FILES=("${INPUTS[@]:0:${#INPUTS[@]}-1}")

set -eu;

function may_copy_into_arch_named_sub_dir() {
  FILE=${1}
  
  echo "FILE is: "${FILE}
  
  COPY_ARCH_RELATED=${COPY_ARCH_RELATED:-1}

  FILE_INFO=$(file "${FILE}" || true)
  
  echo "FILE_INFO is: "${FILE_INFO}
  
  # when file is an `ELF 64-bit LSB`,
  # will put an arch named sub dir
  # like
  #   arm64/
  #   amd64/
  if [[ ${FILE_INFO} == *"ELF 64-bit LSB"* ]]; then
    chmod 755 "${FILE}"
    
    echo "DOCKER_WORKING_DIR is:" ${DOCKER_WORKING_DIR}

    case ${FILE_INFO} in
      *x86-64*)
        echo "Now FILE is of amd64 type ...................."
        mkdir -p "${DOCKER_WORKING_DIR}/amd64/" && cp -rp "${FILE}" "${DOCKER_WORKING_DIR}/amd64/"
        ;;
      *aarch64*)
        echo "Now FILE is of aarch64 type ...................."
        mkdir -p "${DOCKER_WORKING_DIR}/arm64/" && cp -rp "${FILE}" "${DOCKER_WORKING_DIR}/arm64/"
        ;;
      *)
        cp -rp "${FILE}" "${DOCKER_WORKING_DIR}"
        ;;
    esac


    if [[ ${COPY_ARCH_RELATED} == 1 ]]; then
      # if other arch files exists, should copy too.
      
      for ARCH in "amd64" "arm64"; do
        # like file `out/linux_amd64/pilot-discovery`
        # should check  `out/linux_arm64/pilot-discovery` exists then do copy

        FILE_ARCH_RELATED=${FILE/linux_${TARGET_ARCH}/linux_${ARCH}}
        
        echo "FILE_ARCH_RELATED is:" ${FILE_ARCH_RELATED}

        if [[ ${FILE_ARCH_RELATED} != "${FILE}" && -f ${FILE_ARCH_RELATED} ]]; then
          COPY_ARCH_RELATED=0 may_copy_into_arch_named_sub_dir "${FILE_ARCH_RELATED}"
        fi
      done
    fi

  else
    echo "FILE is Not ELF, just copy to working dir: "${FILE}
    cp -rp "${FILE}" "${DOCKER_WORKING_DIR}"
  fi
}

mkdir -p "${DOCKER_WORKING_DIR}"
echo "DOCKER_WORKING_DIR is:"${DOCKER_WORKING_DIR}
for FILE in "${FILES[@]}"; do
  may_copy_into_arch_named_sub_dir "${FILE}"
done
