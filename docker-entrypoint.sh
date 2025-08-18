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
    while ! psql -h "$1" -U db_owner -d db -v ON_ERROR_STOP=1 -Atq -f "$sqlfilename"; do
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
    while ! psql -h "$1" -U db_owner -d db -v ON_ERROR_STOP=1 -Atq -f "$sqlfilename" | grep "$matched_record"; do
        sleep 10
    done
}

function create_git_working_copy {
    # Initialize the shared directory if necessary
    if [ -z "$( ls -A ${SHARED_DIRECTORY})" ]; then
      GIT_REPOSITORY="ssh://git@${GIT_SERVER}:${GIT_PORT}${GIT_REPOSITORY_PATH}"
      ssh-keyscan -p "${GIT_PORT}" -t rsa "${GIT_SERVER}" > /etc/ssh/ssh_known_hosts
      git clone "${GIT_REPOSITORY}" "${SHARED_DIRECTORY}"
      cp -n /etc/ssh/ssh_known_hosts "${SHARED_DIRECTORY}/.ssh_known_hosts"
    fi
    cd "${SHARED_DIRECTORY}"

    # Ensure ".ssh_known_hosts" and "/etc/ssh/ssh_known_hosts" files exist
    if ! [ -e .ssh_known_hosts ]; then
      ssh-keyscan -p "${GIT_PORT}" -t rsa "${GIT_SERVER}" > .ssh_known_hosts
    fi
    cp -n .ssh_known_hosts /etc/ssh/ssh_known_hosts

    # Ensure a symlink to "${OVERLAY_SUBDIR}" exists
    if ! [ -e .overlay ]; then
      ln -ns "${OVERLAY_SUBDIR}" .overlay
    fi
}

function add_phase2_job {
    # This loop periodically pulls the Git repository
    while true; do
      git pull --ff-only

      # Seep for $GIT_PULL_SECONDS seconds (60 by default)
      sleep "${GIT_PULL_SECONDS-60}"
    done
}

case $1 in
    prepare-for-draining)
        set_sentinel "$SHARD_DB_HOST" 1 "$SHARD_DB_HOST"

        # Wait for the sentinel value to be replicated to the child databases.
        match_sentinel "$SHARD0_DB_HOST" 1 "$SHARD_DB_HOST"
        match_sentinel "$SHARD1_DB_HOST" 1 "$SHARD_DB_HOST"

        # Make a commit to the GitOps repository.
        # TODO: add_phase2_job
        ;;
    *)
        exec "$@"
        ;;
esac
