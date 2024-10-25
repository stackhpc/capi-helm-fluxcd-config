# capi-helm-fluxcd-config

This repository contains configuration for deploying and operating
[Kubernetes](https://kubernetes.io/) clusters on [OpenStack](https://www.openstack.org/) using a
[GitOps](https://about.gitlab.com/topics/gitops/) workflow.

The specific tools used to accomplish this are [Cluster API](https://cluster-api.sigs.k8s.io/) for
the Kubernetes provisioning, [Flux CD](https://fluxcd.io/) for automation and
[sealed secrets](https://github.com/bitnami-labs/sealed-secrets) for managing secrets.

Cluster API is a set of
[Kubernetes operators](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/) with
associated
[custom resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
that allow Kubernetes clusters to be provisioned and operated by creating instances of those
resources in a "management" Kubernetes cluster.

The clusters created using configurations derived from this repository are "self-managed". This
means that the Cluster API controllers and the resources defining the cluster are managed on the
cluster itself.

## Bootstrapping a cluster

The use of self-managed clusters creates a bootstrapping problem, i.e. how does the cluster get
created if it manages itself? The solution to this is to use a one-off bootstrapping process that
performs the following steps:

  1. Create an ephemeral Kubernetes cluster using [kind](https://kind.sigs.k8s.io/)
  2. Use the ephemeral cluster to create the Cluster API cluster
       * Install Flux on the ephemeral cluster
       * Use Flux to install the Cluster API controllers on the ephemeral cluster
       * Use Flux to create the Cluster API cluster using the ephemeral cluster
       * Wait for the Cluster API cluster to become ready
  3. Get the `kubeconfig` file for the Cluster API cluster
  4. Install Flux and the Cluster API controllers on the Cluster API cluster
  5. Move the Cluster API resources from the ephemeral cluster to the Cluster API cluster
       * Suspend reconciliation of the Cluster API resources on the ephemeral cluster
       * Copy the Cluster API resources to the Cluster API cluster
       * Resume reconciliation of the Cluster API resources on the Cluster API cluster

At this point, the cluster is self-managed. The remaining steps set the cluster up to be managed
using Flux going forward:

  6. Use Flux to install the sealed secrets controller
  7. Seal the cluster credentials using `kubeseal`
  8. Commit the sealed secret to git and push it
  9. Create a Flux source pointing at the git repository
       * If you are using git over SSH, this will generate an SSH keypair and prompt you
         to add the public key to the git repository as a deploy key
 10. Create a Flux kustomization pointing at the cluster configuration

At this point, the cluster is self-managed using Flux and the ephemeral cluster is deleted.

This repository includes [a Python script](./bin/manage) that performs these steps (see below).

## Usage

First, create a copy of the repository (like a fork but detached).

```sh
# Clone the repository
git clone https://github.com/stackhpc/capi-helm-fluxcd-config.git my-cluster-config
cd my-cluster-config

# Rename the origin remote to upstream so that we can pull changes in future
git remote rename origin upstream

# Add the new origin remote and push the initial commit
git remote add origin <url>
git push -u origin main
```

Create a cluster configuration under the `./clusters` directory, following the
[example](./clusters/example/).

As part of this process, you must create an
[application credential](https://docs.openstack.org/keystone/latest/user/application_credentials.html)
for the target project in OpenStack. The `credentials.yaml` file in the cluster configuration
must then be updated with the following information:

  * The OpenStack auth URL and region, which you can get from your cloud admin
  * The ID and secret of the application credential
  * The ID of the target project in OpenStack

During the bootstrap process, this file will be encrypted using
[kubeseal](https://github.com/bitnami-labs/sealed-secrets) and pushed to the git repository.
Be careful to **NEVER** commit the unencrypted version.

Once you are happy with your cluster configuration, you can bootstrap the cluster.

The following tools are required to execute the bootstrap script:

  * [Python 3](https://www.python.org/)
  * [git](https://git-scm.com/)
  * [Docker](https://docs.docker.com/)
  * [kind](https://kind.sigs.k8s.io/)
  * [kustomize](https://kustomize.io/)
  * [kubeseal](https://github.com/bitnami-labs/sealed-secrets?tab=readme-ov-file#kubeseal)
  * [flux CLI](https://fluxcd.io/flux/cmd/)

Next, create a Python environment with the required dependencies installed, e.g.:

```sh
python3 -m venv ./.venv
source .venv/bin/activate
pip install -U pip
pip install -r requirements.txt
```

Then run the bootstrap command for the cluster that you created:

```sh
./bin/manage bootstrap my-cluster
```

Once the bootstrap is complete, you will have a cluster that can be managed by making changes
to the git repository.

## Accessing the cluster

The bootstrap process produces a cluster-admin `kubeconfig` file that can be used to access the cluster,
which is written into the directory containing the cluster configuration.

> **WARNING**
>
> The `kubeconfig` file is **NOT** committed to git, and if lost is difficult to recover.
>
> It should be stored somewhere safe where it can be shared with team members who need it.

Alternatively, authenticating with the cluster's Kubernetes API server via OIDC is also supported.
The `example` cluster config includes the minimum required cluster configuration (issuer URL, client ID
and a ClusterRoleBinding definition) for this integration. The required configuration for the OIDC provider
and additional cluster config options are described in the corresponding
[capi-helm-charts documentation](https://github.com/azimuth-cloud/capi-helm-charts/tree/main/charts/openstack-cluster#openid-connect-authentication).

If the `oidc` key is present in the cluster's config map during the bootstrap process, then an additional
`kubeconfig-oidc` file will be written alongside the cluster-admin kubeconfig. Unlike the admin version,
the OIDC kubeconfig can be safely added to git and shared with other cluster users. When another user passes
this kubeconfig to `kubectl` a browser window will be opened to allow them to sign in to the configured OIDC
provider and be granted access to the cluster.

If a new OIDC kubeconfig needs to be generated after initial cluster bootstrap then the provided
`bin/generate-oidc-kubeconfig.sh` script may be used directly.
