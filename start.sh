#!/bin/bash
set -e -o pipefail

# default values which can be overriden by -f or -p flags
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

env() {
    if [ ! -f ".env" ]; then
        echo 'You need a configuration file with credentials.'
        echo 'Copying .env.example to .env'
        cp .env.example .env
        cat .env.example
        exit 1
    else
        . .env
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

# Gets the IP of the local machine.
getIp() {
    HOSTNAME_VAL="$(hostname -i)"

    if [ -z $HOSTNAME_VAL ]; then
        IP="127.0.0.1"
    else
        IP=$HOSTNAME_VAL
    fi

    echo $IP
}


# get the IP:port of a container via either the local docker-machine or from
# sdc-listmachines.
getIpPort() {
    if [ -z "${COMPOSE_CFG}" ]; then
        local ip=$(sdc-listmachines --name ${PREFIX}_$1_1 | json -a ips.1)
        local port=$2
    else
        local ip=$(docker-machine ip default 2>/dev/null || true)
        local port=$(docker inspect ${PREFIX}_$1_1 | json -a NetworkSettings.Ports."$2/tcp".0.HostPort)
    fi
    echo "${ip:-`getIp`}:$port"
}

# start and initialize the Couchbase cluster, along with Consul
startDatabase() {
    echo
    echo 'Starting Couchbase'
    ${COMPOSE} up -d --no-recreate couchbase
    echo
    echo -n 'Initializing cluster.'

    sleep 1.3
    COUCHBASERESPONSIVE=0
    while [ $COUCHBASERESPONSIVE != 1 ]; do
        echo -n '.'
        RUNNING=$(docker inspect "${PREFIX}_couchbase_1" | json -a State.Running)
        if [ "$RUNNING" == "true" ]
        then
            docker exec -it "${PREFIX}_couchbase_1" triton-bootstrap bootstrap benchmark
            let COUCHBASERESPONSIVE=1
        else
            sleep 1.3
        fi
    done
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
    echo 'The username and password are printed in earlier messages'
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
    removeBucket benchmark
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
    echo "Waiting for Nginx at $NGINX to pick up initial configuration."
    while :
    do
        sleep 1
        curl -s --fail -o /dev/null "http://${NGINX}" && break
        echo -ne .
    done
    echo
    echo 'Opening web page...'
    command -v open >/dev/null 2>&1 && `open http://${NGINX}` || true
}

startCloudflare() {
    ${COMPOSE} up -d cloudflare
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
	docker tag -f tb_touchbase 0x74696d/triton-touchbase
	docker tag -f tb_nginx 0x74696d/triton-touchbase-demo-nginx
	docker push 0x74696d/triton-touchbase
	docker push 0x74696d/triton-touchbase-demo-nginx
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

cmd=$1
if [ ! -z "$cmd" ]; then
    shift 1
    $cmd "$@"
    exit
fi

env
prep
startDatabase
showConsoles
setupCouchbase
startApp
startNginx
startCloudflare

echo
echo 'Touchbase cluster is launched!'
echo "Try scaling it up by running: ./start.sh ${COMPOSE_CFG:-} scale"
