Swaptacular shard-splitting utility for Kubernetes clusters
===========================================================

This project implements a utility container used to automate the
shard-splitting process, when deploying [Swaptacular] in [Kubernetes]
clusters. The ultimate deliverable is a [docker image], generated from
the project's [Dockerfile](../master/Dockerfile).

**Note:** This project is tightly coupled with the [Swaptacular GitOps
repository for deploying to Kubernetes
clusters](https://github.com/swaptacular/swpt-k8s-config) project, and
only functions meaningfully within its context.

Configuration
-------------

The behavior of the running container can be tuned with environment
variables. Here are the most important settings with some random
example values:

```shell
APP_K8S_NAMESPACE=swpt-accounts

WORKING_DIRECTORY=/mnt/git-ops
GIT_SERVER=git-server.simple-git-server.svc.cluster.local
GIT_PORT=2222
GIT_REPOSITORY_PATH=/srv/git/fluxcd.git

SHARDS_APP=swpt-accounts-shard
SHARDS_CRITICAL_WORKLOADS=http-cache web-server
SHARDS_COMPONENTS=chores-consumer messages-consumer messages-flusher tasks-processor web-server
SHARDS_PREFIX=shard
SHARDS_PG_CLUSTER_PREFIX=db
SHARD_SUFFIX=
SHARD0_SUFFIX=-0
SHARD1_SUFFIX=-1
SHARD_ROUTING_KEY=#
SHARD0_ROUTING_KEY=0.#
SHARD1_ROUTING_KEY=1.#
APIPROXY_CONFIG=../../apiproxy.conf
CONSUMER_TASK_NAME=messages-consumer
DRAINER_TASK_NAME=messages-drainer
SHARDS_SUBDIR=apps/dev/swpt-accounts/shards
```

Available commands
------------------

The [entrypoint](../master/docker-entrypoint.sh) of the docker
container allows you to execute the following *documented commands*:

* `wait-for-pods-termination`
* `prepare-for-draining`
* `prepare-for-running-new-shards`
* `prepare-for-old-shard-removal`


[Swaptacular]: https://swaptacular.github.io/overview
[Kubernetes]: https://kubernetes.io/
[docker image]: https://www.geeksforgeeks.org/what-is-docker-images/
