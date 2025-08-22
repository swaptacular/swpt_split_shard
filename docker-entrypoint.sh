#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# NOTE: The PGPASSWORD envvar must contain the password for the
#       database.

# Make sure we react to these signals by running stop() when we see them - for clean shutdown
# And then exiting
trap "stop; exit 0;" SIGTERM SIGINT

stop()
{
  # We're here because we've seen SIGTERM, likely via a Docker stop command or similar
  # Let's shutdown cleanly
  echo "SIGTERM caught, terminating..."
  echo "Terminated."
  exit
}

# This function continuously tries to make a database connection to
# $1, and insert a (id=$2, value=$3) record in the "shard_split_guard"
# table.
function set_sentinel {
    echo "Tying to set shard split guard in $1 (id=$2, value=$3) ..."
    sqlfilename="$(mktemp)"
    set_record="Successfully set split guard (id=$2, value=$3)."
    cat > "$sqlfilename" <<EOF
CREATE TABLE IF NOT EXISTS shard_split_guard (id smallint PRIMARY KEY, value text);

INSERT INTO shard_split_guard (id, value) VALUES ($2, '$3')
ON CONFLICT (id)
DO UPDATE SET value=EXCLUDED.value;

SELECT '$set_record' FROM pg_switch_wal();
EOF
    while ! psql -h "$1" -d db -v ON_ERROR_STOP=1 -Atq -f "$sqlfilename"; do
        sleep 10
    done
}

# This function continuously tries to make a database connection to
# $1, and ensure that a (id=$2, value=$3) record exists the
# "shard_split_guard" table.
function match_sentinel {
    echo "Waiting for shard split guard in $1 (id=$2, value=$3) ..."
    sqlfilename="$(mktemp)"
    matched_record="Found split guard (id=$2, value=$3)."
    cat > "$sqlfilename" <<EOF
SELECT '$matched_record'
FROM shard_split_guard
WHERE id=$2 AND value='$3';
EOF
    while ! psql -h "$1" -d db -v ON_ERROR_STOP=1 -Atq -f "$sqlfilename" | grep "$matched_record"; do
        sleep 10
    done
}

function init_working_directory {
    echo 'Initializing the working directory ...'
    pushd . > /dev/null

    if [ -z "$( ls -A ${WORKING_DIRECTORY})" ]; then
      GIT_REPOSITORY="ssh://git@${GIT_SERVER}:${GIT_PORT}${GIT_REPOSITORY_PATH}"
      ssh-keyscan -p "${GIT_PORT}" -t rsa "${GIT_SERVER}" > /etc/ssh/ssh_known_hosts
      git clone "${GIT_REPOSITORY}" "${WORKING_DIRECTORY}"
      cp -n /etc/ssh/ssh_known_hosts "${WORKING_DIRECTORY}/.ssh_known_hosts"
    fi
    cd "${WORKING_DIRECTORY}"

    # Ensure ".ssh_known_hosts" and "/etc/ssh/ssh_known_hosts" files exist
    if ! [ -e .ssh_known_hosts ]; then
      ssh-keyscan -p "${GIT_PORT}" -t rsa "${GIT_SERVER}" > .ssh_known_hosts
    fi
    cp -n .ssh_known_hosts /etc/ssh/ssh_known_hosts

    # Configure Git identity.
    git config user.name "splitting-job-bot"
    git config user.email "splitting-job-bot@localhost"

    popd > /dev/null
}

function git_reset_and_pull {
    echo 'Resetting the working directory ...'
    pushd . > /dev/null
    cd "${WORKING_DIRECTORY}"
    git restore --staged --worktree .
    git reset --hard origin/master
    echo 'Pulling from origin/master ...'
    git pull --ff-only
    popd > /dev/null
}

function set_replicas_selector {
    REPLICAS_SELECTOR='.name != ""'
    IFS=$' '
    for workload in ${SHARDS_CRITICAL_WORKLOADS-}
    do
        REPLICAS_SELECTOR+=" and .name != \"$workload\""
    done
    IFS=$'\n\t'
}

# This function continuously tries to create and push a new commit to
# the Git-ops repository. The created commit triggers phase 2 of the
# splitting of the shard.
function schedule_phase2_job {
    set_replicas_selector
    init_working_directory
    shard_subdir="$SHARDS_SUBDIR/$SHARDS_PREFIX$SHARD_SUFFIX"
    cd "${WORKING_DIRECTORY}/$shard_subdir"

    while true; do
        git_reset_and_pull

        # Use the "splitting-phase-2-job.yaml" resource (the scheduled
        # job), instead of the "splitting-phase-1-job.yaml" resource
        # (the currently executing job).
        job_selector='.resources[] | select(. == "*/splitting-phase-1-job.yaml")'
        if [[ "$(yq "$job_selector | kind" kustomization.yaml)" != scalar ]]; then
            echo 'ERROR: Can not locate the "splitting-phase-1-job.yaml" resource!'\
                 'Most probably, the splitting of this shard has been manually canceled.'
            exit 1
        fi
        phase1_job="$(yq "$job_selector" kustomization.yaml)"
        phase2_job="$(echo "$phase1_job" | sed s/1-job.yaml$/2-job.yaml/)"
        yq -i "with($job_selector; . = \"$phase2_job\")" kustomization.yaml

        # Do not start parent shard's processes. Leave only the
        # drainer process.
        consumers_count=$(yq ".replicas[] | select(.name == \"${CONSUMER_TASK_NAME}\") .count" kustomization.yaml)
        yq -i "with(.replicas[] | select(.name == \"$DRAINER_TASK_NAME\"); del(.))" kustomization.yaml
        yq -i "with(.replicas[] | select($REPLICAS_SELECTOR); .count |= 0)" kustomization.yaml
        yq -i ".replicas += [{\"name\": \"$DRAINER_TASK_NAME\", \"count\": $consumers_count}]" kustomization.yaml

        git add -A
        git commit -m "SPLIT: Trigger phase 2 for $shard_subdir"
        if git push; then
            break
        fi

        # Sleep for a random interval between 0 and 32 seconds.
        sleep_seconds=$((RANDOM / 1000))
        echo "Will try again in $sleep_seconds seconds ..."
        sleep $sleep_seconds
    done
}

# This function continuously tries to create and push a new commit to
# the Git-ops repository. The created commit triggers phase 3 of the
# splitting of the shard.
function schedule_phase3_job {
    init_working_directory
    shard_subdir="$SHARDS_SUBDIR/$SHARDS_PREFIX$SHARD_SUFFIX"
    cd "${WORKING_DIRECTORY}/$shard_subdir"

    while true; do
        git_reset_and_pull

        # Use the "splitting-phase-3-job.yaml" resource (the scheduled
        # job), instead of the "splitting-phase-2-job.yaml" resource
        # (the currently executing job).
        job_selector='.resources[] | select(. == "*/splitting-phase-2-job.yaml")'
        if [[ "$(yq "$job_selector | kind" kustomization.yaml)" != scalar ]]; then
            echo 'ERROR: Can not locate the "splitting-phase-2-job.yaml" resource!'\
                 'Most probably, the splitting of this shard has been manually canceled.'
            exit 1
        fi
        phase2_job="$(yq "$job_selector" kustomization.yaml)"
        phase3_job="$(echo "$phase2_job" | sed s/2-job.yaml$/3-job.yaml/)"
        yq -i "with($job_selector; . = \"$phase3_job\")" kustomization.yaml

        # Remove the "standby" section from children Postgres clusters.
        yq -i 'with(.spec; del(.standby))' "../$SHARDS_PREFIX$SHARD0_SUFFIX/postgres-cluster.yaml"
        yq -i 'with(.spec; del(.standby))' "../$SHARDS_PREFIX$SHARD1_SUFFIX/postgres-cluster.yaml"

        # Restore the normal number of replicas for children shards.
        yq -i '.replicas = (load("kustomization.unsplit").replicas)' "../$SHARDS_PREFIX$SHARD0_SUFFIX/kustomization.yaml"
        yq -i '.replicas = (load("kustomization.unsplit").replicas)' "../$SHARDS_PREFIX$SHARD1_SUFFIX/kustomization.yaml"

        # Do not start the drainer process in the parent shard.
        yq -i "with(.replicas[] | select(.name == \"$DRAINER_TASK_NAME\"); del(.))" kustomization.yaml

        # TODO: Edit apiproxy.conf
        echo Editing apiproxy.conf is not implemented yet.
        return 1

        git add -A
        git commit -m "SPLIT: Trigger phase 3 for $shard_subdir"
        if git push; then
            break
        fi

        # Sleep for a random interval between 0 and 32 seconds.
        sleep_seconds=$((RANDOM / 1000))
        echo "Will try again in $sleep_seconds seconds ..."
        sleep $sleep_seconds
    done
}

function terminated_component {
    labels="app.kubernetes.io/name=$SHARDS_APP,app.kubernetes.io/instance=$SHARDS_PREFIX$SHARD_SUFFIX,app.kubernetes.io/component=$1"

    # Ensure there is exactly one deployment and it has 0 replicas.
    [[ "$(kubectl -n "$APP_K8S_NAMESPACE" get deployments -l "$labels" -o 'jsonpath={.items[*].spec.replicas}')" == 0 ]] || return

    # Ensure a replicaset is created for the deployment.
    revision_path='{.items[*].metadata.annotations.deployment\.kubernetes\.io/revision}'
    revision="$(kubectl -n "$APP_K8S_NAMESPACE" get deployments -l "$labels" -o "jsonpath=$revision_path")"
    kubectl -n "$APP_K8S_NAMESPACE" get replicasets -l "$labels" -o "jsonpath=$revision_path"\
        | grep -E "\b$revision\b" > /dev/null || return

    # Ensure all replicasets have 0 running replicas.
    kubectl -n "$APP_K8S_NAMESPACE" get replicasets -l "$labels" -o 'jsonpath={.items[*].spec.replicas}'\
        | tr '\n' ' ' | grep -E '^(0\s)*0\s?$' > /dev/null || return
    kubectl -n "$APP_K8S_NAMESPACE" get replicasets -l "$labels" -o 'jsonpath={.items[*].status.replicas}'\
        | tr '\n' ' ' | grep -E '^(0\s)*0\s?$' > /dev/null || return

    # Ensure there are no running pods.
    pod_names="$(kubectl -n "$APP_K8S_NAMESPACE" get pods -l "$labels" -o 'jsonpath={.items[*].metadata.name}')"
    [[ "$pod_names" == "" ]]
}

# This function returns successfully if all shard components have been
# terminated. Otherwise return a non-zero exit code.
function terminated_components {
    result=0
    IFS=$' '
    for component in $SHARDS_COMPONENTS
    do
        if ! terminated_component "$component"; then
            result=1
            break
        fi
    done
    IFS=$'\n\t'
    return "$result"
}

# This function waits for the sentinel value to be replicated to the
# child databases. The "$1" parameter specifies the "phase" of the
# splitting (1, 2, etc.).
function wait_for_sentinel {
    export PGUSER=postgres  # pg_switch_wal() requires admin privileges.
    export PGPASSWORD="$pg_password"

    shard_pg_cluster_name="$SHARDS_PG_CLUSTER_PREFIX$SHARD_SUFFIX"
    set_sentinel "$shard_pg_cluster_name" $1 "$shard_pg_cluster_name"

    match_sentinel "$SHARDS_PG_CLUSTER_PREFIX$SHARD0_SUFFIX" $1 "$shard_pg_cluster_name"
    match_sentinel "$SHARDS_PG_CLUSTER_PREFIX$SHARD1_SUFFIX" $1 "$shard_pg_cluster_name"
}

case $1 in
    prepare-for-draining)
        wait_for_sentinel 1
        schedule_phase2_job
        ;;
    wait-for-pods-termination)
        while ! terminated_components; do
            sleep 10
        done
        echo 'Shard components have been successfully terminated.'
        ;;
    prepare-for-running-new-shards)
        wait_for_sentinel 2
        schedule_phase3_job
        ;;
    *)
        exec "$@"
        ;;
esac
