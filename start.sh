#!/bin/bash
set -o pipefail

# default values which can be overridden by -f or -p flags
CONFIG_FILE=
PREFIX=tb

usage() {
    echo 'Usage ./start.sh [-f docker-compose.yml] [-p project] [--no-index] [cmd] [args]'
    echo
    echo 'Starts up the entire stack.'
    echo
    echo '-f <filename> [optional] use this file as the docker-compose config file'
    echo '-p <project>  [optional] use this name as the project prefix for docker-compose'
    echo '-h            help. print this thing you are reading now.'
    echo
    echo 'Optionally pass a command and parameters and this script will execute just'
    echo 'that command, for testing purposes.'
}

tritonConfigured() {
    # only check for Triton CLI if we're using the default Compose yaml
    if [ ! -z "${COMPOSE_CFG}" ]; then
        return
    fi

    # is node-triton installed?
    which triton > /dev/null
    if [ $? -ne 0 ]; then
        tput rev
        tput bold
        echo 'Error:'
        echo 'The Triton CLI tool does not appear to be installed'
        tput sgr0
        echo
        echo "Please visit:"
        echo "https://www.joyent.com/blog/introducing-the-triton-command-line-tool"
        echo "for installation instructions."

        exit 1
    fi

    # Get username from Docker
    local docker_user=$(docker info 2>&1 | grep "SDCAccount:" | awk -F": " '{print $2}' OFS="/")

    # Get username from Triton
    local triton_user=$(triton profile get | grep "account:" | awk -F": " '{print $2}' OFS="/")

    # Get DC from Docker
    local docker_dc=$(echo $DOCKER_HOST | awk -F"/" '{print $3}' OFS="/" | awk -F"\." '{print $1}' OFS="/")

    # Get DC from Triton
    local triton_dc=$(triton profile get | grep "url:" | awk -F"/" '{print $3}' OFS="/" | awk -F"\." '{print $1}' OFS="/")

    if [ ! "$docker_user" = "$triton_user" ] || [ ! "$docker_dc" = "$triton_dc" ]; then
        tput rev # reverse foreground and background colors
        tput bold # bold
        echo 'Error:'
        echo 'The Triton CLI configuration does not match the Docker CLI configuration'
        tput sgr0 # clear colors
        echo
        echo "Docker user: ${docker_user}"
        echo "Triton user: ${docker_user}"
        echo
        echo "Docker data center: ${docker_dc}"
        echo "Triton data center: ${triton_dc}"
        echo
        echo "The Triton CLI tool must be configured to use the same user and data center as the Docker CLI."
        echo
        echo "Please visit:"
        echo "https://www.joyent.com/blog/introducing-the-triton-command-line-tool#using-profiles"
        echo "for instructions on how to configure and set profiles for Triton."

        exit 1
    fi

    # Is Triton CNS enabled
    local triton_cns_enabled=$(triton account get | grep cns | awk -F": " '{print $2}' OFS="/")

    if [ ! "true" = "$triton_cns_enabled" ]; then
        tput rev
        tput bold
        echo 'Notice:'
        echo 'Triton CNS is not enabled for this account'
        tput sgr0
        echo
        echo "Triton CNS, an automated DNS built into Triton, is not required, but this blueprint demonstrates its use."
        echo
        echo "Please visit:"
        echo "https://www.joyent.com/blog/introducing-triton-container-name-service"
        echo "for information and usage details for Triton CNS."
        echo
        echo "Enable Triton CNS with the following command:"
        echo
        echo "triton account update triton_cns_enabled=true"
    fi
}

env() {
    if [ ! -f "_env" ]; then
        echo 'Creating an empty configuration file for Couchbase credentials.'
        echo 'Copying _env.example to _env'
        echo
        echo 'Recommended: enter a custom database admin user/pass'
        echo 'in the following _env file and re-run this script.'
        echo
        cp _env.example _env
        cat _env.example
        exit 1
    else
        . _env
    fi
    export COUCHBASE_USER=${COUCHBASE_USER:-Administrator}
    export COUCHBASE_PASS=${COUCHBASE_PASS:-password}
    CB_RAM_QUOTA=${CB_RAM_QUOTA:-100}
}

prep() {
    echo "Starting example application"
    echo "project prefix:      $PREFIX"
    echo "docker-compose file: $CONFIG_FILE"
    echo
    echo 'Pulling latest container images'
    ${COMPOSE} pull
}

# get the IP:port of a container via either the local docker-machine or from
# triton inst get $instance_name.
getIpPort() {
    if [ -z "${COMPOSE_CFG}" ]; then
        # try to get a DNS name from Triton CNS
        local ip=$(triton inst get ${PREFIX}_$1_1 | json -a dns_names | grep "\.svc\." | tail -1 | awk -F"\"" '{print $2}')
        if [ -z "$ip" ]; then
            # fail back to the IP number, if CNS is not active
            local ip=$(triton inst get ${PREFIX}_$1_1 | json -a ips.1)
        fi
        local port=$2
    else
        local ip=$(docker-machine ip default 2>/dev/null || true)
        local port=$(docker inspect ${PREFIX}_$1_1 | json -a NetworkSettings.Ports."$2/tcp".0.HostPort)
    fi
    echo "${ip:-`hostname -i`}:$port"
}

# start and initialize the Couchbase cluster, along with Consul
startDatabase() {
    echo
    echo 'Starting Couchbase'
    ${COMPOSE} up -d --no-recreate couchbase
}

# open the web consoles
showConsoles() {
    local CONSUL=$(getIpPort consul 8500)
    echo
    echo 'Consul is now running'
    echo "Dashboard: $CONSUL"
    command -v open >/dev/null 2>&1 && `open http://${CONSUL}/ui/` || true

    local CBDASHBOARD=$(getIpPort couchbase 8091)
    echo
    echo 'Couchbase cluster running and bootstrapped'
    echo "Dashboard: $CBDASHBOARD"
    command -v open >/dev/null 2>&1 && `open http://${CBDASHBOARD}/index.html#sec=servers` || true
}

# send a REST API call to remove a CB bucket
removeBucket() {
    docker exec -it ${PREFIX}_couchbase_1 \
           /opt/couchbase/bin/couchbase-cli bucket-delete -c 127.0.0.1:8091 \
           -u ${COUCHBASE_USER} -p ${COUCHBASE_PASS} \
           --bucket=$1
}

# use Docker exec to use the Couchbase CLI to create a CB bucket;
# this avoids using the REST API so we don't have to deal with proxy port
# configuration
createBucket() {
    docker exec -it ${PREFIX}_couchbase_1 \
           /opt/couchbase/bin/couchbase-cli bucket-create -c 127.0.0.1:8091 \
           -u ${COUCHBASE_USER} -p ${COUCHBASE_PASS} \
           --bucket=$1 \
           --bucket-type=couchbase \
           --bucket-ramsize=${CB_RAM_QUOTA} \
           --bucket-replica=1 \
           --wait # need to wait otherwise index creation can fail later
}

# send a REST API call to Couchbase to create a N1QL index
createIndex() {
    echo $1
    docker exec -it ${PREFIX}_couchbase_1 \
           curl -s --fail -X POST http://${N1QLAPI}/query/service \
           -u ${COUCHBASE_USER}:${COUCHBASE_PASS} \
           -d "statement=$1"
}

# create all buckets and indexes we need. if you modify the names
# of the buckets in config.json you'll need to modify this section
setupCouchbase() {
    CBAPI=$(getIpPort couchbase 8091)
    N1QLAPI=$(getIpPort couchbase 8093)
    echo
    echo 'Creating Couchbase buckets'
    while true; do
        echo -n '.'
        curl -sf -u ${COUCHBASE_USER}:${COUCHBASE_PASS} \
             -o /dev/null http://${CBAPI}/pools/nodes && break
        sleep 1.3
    done
    echo

    createBucket users
    createBucket users_pictures
    createBucket users_publishments

    echo 'Creating Couchbase indexes'
    createIndex 'CREATE PRIMARY INDEX ON users'
    createIndex 'CREATE PRIMARY INDEX ON users_pictures'
    createIndex 'CREATE PRIMARY INDEX ON users_publishments'
}

# write a template file for consul-template to a key in Consul.
# the key will be written to <service>/template.
# usage:
# writeTemplate <service> <relative/path/to/template>
writeTemplate() {
    local CONSUL=$(getIpPort consul 8500)
    local service=$1
    local template=$2
    echo "Writing $template to key $service/template in Consul"
    while :
    do
        # we'll sometimes get an HTTP500 here if consul hasn't completed
        # it's leader election on boot yet, so poll till we get a good response.
        sleep 1
        curl --fail -s -X PUT --data-binary @$template \
             http://${CONSUL}/v1/kv/$service/template && break
        echo -ne .
    done
}

# start up the Touchbase application
startApp() {
    writeTemplate touchbase ./config.json.ctmpl
    echo
    ${COMPOSE} up -d touchbase
    local TB=$(getIpPort touchbase 3000)
}

# start up Nginx and launch it in the browser
startNginx() {
    writeTemplate nginx ./nginx/default.ctmpl
    echo
    ${COMPOSE} up -d nginx
    local NGINX=$(getIpPort nginx 80)
    echo 'Waiting for Nginx to pick up initial configuration.'
    echo "Trying http://${NGINX} ..."
    while :
    do
        sleep 1
        curl -s --fail -o /dev/null "http://${NGINX}" && break
        echo -ne .
    done
    echo
    echo 'Opening Touchbase app at'
    echo "http://${NGINX}"
    command -v open >/dev/null 2>&1 && `open http://${NGINX}` || true
}

startTelemetry() {
    ${COMPOSE} up -d prometheus
    local PROM=$(getIpPort prometheus 9090)
    echo 'Waiting for Prometheus...'
    while :
    do
        sleep 1
        curl -s --fail -o /dev/null "http://${PROM}/metrics" && break
        echo -ne .
    done
    echo
    echo 'Opening Prometheus expression browser at'
    echo "http://${PROM}/graph"
    command -v open >/dev/null 2>&1 && `open http://${PROM}/graph` || true
}

# scale the entire application to 2 Nginx, 3 app servers, 3 CB nodes
scale() {
    echo
    echo 'Scaling cluster to 3 Couchbase nodes, 3 app nodes, 2 Nginx nodes.'
    ${COMPOSE} scale couchbase=3
    ${COMPOSE} scale touchbase=3
    ${COMPOSE} scale nginx=2
}

# build and ship the Touchbase image and the supporting Nginx
# image to the Docker Hub
release() {
	docker-compose -p tb -f docker-compose-local.yml build touchbase
	docker-compose -p tb -f docker-compose-local.yml build nginx
	docker tag -f tb_touchbase autopilotpattern/touchbase
	docker tag -f tb_nginx autopilotpattern/touchbase-demo-nginx
	docker push autopilotpattern/touchbase
	docker push autopilotpattern/touchbase-demo-nginx
}

while getopts "f:p:h" optchar; do
    case "${optchar}" in
        f) CONFIG_FILE=${OPTARG} ;;
        p) PREFIX=${OPTARG} ;;
        h) usage; exit 0;;
    esac
done
shift $(expr $OPTIND - 1 )

COMPOSE_CFG=
if [ -n "${CONFIG_FILE}" ]; then
    COMPOSE_CFG="-f ${CONFIG_FILE}"
fi

COMPOSE="docker-compose -p ${PREFIX} ${COMPOSE_CFG}"

tritonConfigured
env

cmd=$1
if [ ! -z "$cmd" ]; then
    shift 1
    $cmd "$@"
    exit
fi

prep
startDatabase
showConsoles
setupCouchbase
startApp
startNginx
startTelemetry

echo
echo 'Touchbase cluster is launched!'
echo "Try scaling it up by running: ./start.sh ${COMPOSE_CFG:-} scale"
