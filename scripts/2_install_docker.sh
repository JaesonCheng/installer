#!/bin/bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./util.sh
. "${BASE_DIR}/utils.sh"

# shellcheck source=./0_prepare.sh
. "${BASE_DIR}/0_prepare.sh"

DOCKER_CONFIG="/etc/docker/daemon.json"
docker_config_change=0
docker_copy_failed=0

cd "${BASE_DIR}" || exit

function copy_docker() {
  cp ./docker/* /usr/bin/ \
  && cp ./docker.service /etc/systemd/system/ \
  && chmod +x /usr/bin/docker* \
  && chmod 754 /etc/systemd/system/docker.service
  if [[ "$?" != "0" ]]; then
    docker_copy_failed=1
  fi
}

function install_docker() {
  if [[ ! -f ./docker/dockerd || ! -f ./docker/docker-compose ]]; then
    rm -rf ./docker
    prepare_docker_bin
  fi
  if [[ ! -f ./docker/dockerd ]]; then
    echo_red "Error: $(gettext -s 'Docker program does not exist')"
    exit
  fi

  docker_exist=1
  docker_version_match=1
  old_docker_md5=$(get_file_md5 /usr/bin/dockerd)
  new_docker_md5=$(get_file_md5 ./docker/dockerd)

  if [[ ! -f "/usr/bin/dockerd" ]]; then
    docker_exist=0
  elif [[ "${old_docker_md5}" != "${new_docker_md5}" ]]; then
    docker_version_match=0
  fi

  if [[ "${docker_exist}" != "1" ]]; then
    copy_docker
  elif [[ "${docker_version_match}" != "1" ]]; then
    confirm="n"
    read_from_input confirm "$(gettext -s 'There are updates available currently. Do you want to update')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      copy_docker
    fi
  fi

  if [[ "${docker_copy_failed}" != "0" ]]; then
    echo_red "Docker $(gettext -s 'File copy failed. May be that docker service is already running. Please stop the running docker and re-execute it')"
    echo_red "systemctl stop docker"
    exit 1
  fi

  old_docker_compose_md5=$(get_file_md5 /usr/bin/docker-compose)
  new_docker_compose_md5=$(get_file_md5 ./docker/docker-compose)
  if [[ ! -f "/usr/bin/docker-compose" || "${old_docker_compose_md5}" != "${new_docker_compose_md5}" ]]; then
    cp ./docker/docker-compose /usr/bin/
    chmod +x /usr/bin/docker-compose
  fi
  echo_done
}

function set_docker_config() {
  key=$1
  value=$2

  if [[ ! -f "${DOCKER_CONFIG}" ]]; then
    config_dir=$(dirname ${DOCKER_CONFIG})
    if [[ ! -d ${config_dir} ]]; then
      mkdir -p "${config_dir}"
    fi
    echo -e "{\n}" >>${DOCKER_CONFIG}
  fi
  $(python -c "import json
key = '${key}'
value = '${value}'
try:
    value = json.loads(value)
except:
    pass
filepath = \"${DOCKER_CONFIG}\"
f = open(filepath);
config = json.load(f);
config[key] = value
f.close();
f = open(filepath, 'w');
json.dump(config, f, indent=True, sort_keys=True);
f.close()
")
}

function config_docker() {
  if [[ -f '/etc/docker/daemon.json' ]]; then
    cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
  fi
  echo "$(gettext -s 'Modify the default storage directory of Docker image, you can select your largest disk and create a directory in it, such as') /opt/docker"
  df -h | grep -v map | grep -v devfs | grep -v tmpfs | grep -v "overlay" | grep -v "shm"

  docker_storage_path='/opt/docker'
  echo ""
  read_from_input docker_storage_path "$(gettext -s 'Docker image storage directory')" '' "${docker_storage_path}"

  if [[ ! -d "${docker_storage_path}" ]]; then
    mkdir -p ${docker_storage_path}
  fi
  set_docker_config data-root "${docker_storage_path}"
  set_docker_config log-driver "json-file"
  set_docker_config log-opts '{"max-size": "10m", "max-file": "3"}'
  diff /etc/docker/daemon.json /etc/docker/daemon.json.bak &>/dev/null
  if [[ "$?" != "0" ]]; then
    docker_config_change=1
  fi
  echo_done
}

function start_docker() {
  systemctl daemon-reload
  docker_is_running=$(is_running dockerd)

  ret_code='1'
  if [[ "${docker_is_running}" && "${docker_version_match}" != "1" || "${docker_config_change}" == "1" ]]; then
    confirm="y"
    read_from_input confirm "$(gettext -s 'Docker version has changed or Docker configuration file has been changed, do you want to restart')?" "y/n" "${confirm}"
    if [[ "${confirm}" != "n" ]]; then
      systemctl restart docker
      ret_code="$?"
    fi
  else
    systemctl start docker
    ret_code="$?"
  fi
  systemctl enable docker &>/dev/null
  if [[ "$ret_code" == "0" ]];then
    echo_done
  else
    echo_failed
  fi
}

function main() {
  if [[ "${OS}" == 'Darwin' ]]; then
    echo "$(gettext -s 'Skip docker installation on MacOS')"
    return
  fi
  echo_yellow "1. $(gettext -s 'Install Docker')"
  install_docker
  echo_yellow "\n2. $(gettext -s 'Configure Docker')"
  config_docker
  echo_yellow "\n3. $(gettext -s 'Start Docker')"
  start_docker
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
