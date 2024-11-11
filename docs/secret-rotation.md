# Secret Rotation

This brief guide should outline all the steps needed to be able to swap out a set of secrets or credentials with FluxCD GitOps.

## Contents

### [Pre-requisites](#pre-requisites-1)
- [Applications & Software](#applications--software)

### [Outline](#outline-1)
- [Cluster Maintenance](#cluster-maintenance)
  - Basics of what is done in a standard secret rotation.
- [Security Threat](#security-threat)
  - What to do in the case of a compromised secret.

### [Horizon Application Credentials](#horizon-application-credentials-1)
- [Create/Delete Credentials](#createdelete-credentials)
  - How to create & delete application credentials within Horizon.

### [Processing Secrets](#processing-secrets-1)
- [Encrypting Credentials](#encrypting-new-credential)
  - Using Kubeseal to encrypt the newly created credentials.
- [Updating Secrets](#updating-secrets)
  - How to rotate new secrets using FluxCD’s GitOps.
- [Deleting Old Secrets](#deleting-old-secrets)
  - Some housekeeping steps post secret rotation.
- [Rotating Compromised Secrets](#rotating-compromised-secrets)
  - Summary for the rotation of secrets posing a security threat.

### [Validate Configuration](#validate-configuration-1)
- [Pod Status](#pod-status)
  - How to check the state of pods post secret rotation.
- [Sonobuoy](#sonobuoy)
  - Brief outline on validating the Kubernetes configuration.

#
# Pre-Requisites

This document assumes that a self-managed Cluster API (CAPI) cluster deployed with FluxCD is already configured and deployed, if not, one can be deployed by following the instructions found in [this](https://github.com/stackhpc/capi-helm-fluxcd-config) GitHub repository.

In addition to this, the user trying to rotate the secrets should have an account on Horizon with the necessary permissions.

### Applications & Software

> [!NOTE]
> This document assumes that the Kubernetes cluster’s ```kubeconfig``` is known and can be found in ```clusters/<cluster-name>/```.

Kubeseal

Current CAPI cluster FluxCD config

Horizon account

k9s (for debugging, optional)

# **Outline**

The overall idea is to take advantage of Kubeseal’s encryption, allowing us to upload secrets to our repositories; meaning that after a branch containing the new secrets is merged into the branch being tracked by FluxCD, the FluxCD GitOps flow will update the current cluster deployment to reflect the newly merged branch.

Although the basic outline will remain the same, there are some variations in the preliminary actions depending on the situation and reason why secrets are being rotated.

The two main categories fall under **cluster maintenance** and **security threat**, and the differences in these situations will be further explained below.

### **Cluster Maintenance**

It is often a good idea and good security practice to rotate passwords and secrets, as it reduces the chances of them existing long enough for them to be exploited or end up in the wrong hands; often many secrets will have an expiration date precisely for this reason.

Therefore, in the case of the user simply updating secrets for the purpose of cluster maintenance it is simply enough to replace the current Kubeseal encrypted secret with an updated, manually encrypted, `kubeseal` secret via a GitHub pull request and merge. Then delete the old application credential from Horizon.

###	**Security Threat**

In the event that the existence of a secret is a cause for concern, such as the current uploaded secret being unencrypted or leaked, then the protocol is mainly the same apart from needing to delete the application credential from Horizon first before any other step. At which point the compromised secret is no longer valid and anyone using it won’t be able to do anything with it.

# **Horizon Application Credentials**

### **Create/Delete Credentials**

The first step is to access the Horizon application credentials in order to either create a new one or to delete the old, compromised secret.

Application credentials can be managed through the use of the openstack CLI which can be found [here](https://docs.openstack.org/keystone/2024.2/user/application_credentials.html), however, for the sake of simplicity, the following steps will outline how to do this through the Horizon dashboard user interface.

Once logged into Horizon, head to the **Identity** tab on the left, then **Application Credentials**. From this page, it is possible to manage the secrets which authenticate operations targetted at the OpenStack system.

> [!IMPORTANT]
> If the credential’s been compromised, this is the point in which the application credential will need to be deleted.

In the case of creating a new set of application credentials, please remember to download the **clouds.yaml** once the configuration steps are complete; this will be the only time you will be able to do so, otherwise a new set of credentials will need to be created.

At this point, the newly created secret requires encrypting before it can be rotated in.

# **Processing Secrets**

### **Encrypting New Credential**

Once the new secret **clouds.yaml** has been downloaded, and before going any further, it would be a good idea to rename the old **credentials.yaml** in `fluxcd-config/clusters/<cluster-name>/` into something like **old-credentials.yaml** \- *of course, only if the secret hasn’t already been deleted in Horizon or is suspected to be compromised*.

Now a new file called **credentials.yaml** can be created in its place with the following structure:

```
apiVersion: v1
kind: Secret
metadata:
  name: <MAKE SURE THIS MATCHES “cloudCredentialsSecretName:” IN configmap.yaml>
  namespace: capi-self
  annotations:
    # Allow the sealed secret controller to take over this secret after bootstrapping
    sealedsecrets.bitnami.com/managed: "true"
stringData:
  clouds.yaml: |
    <INSERT THE CONTENTS OF YOUR NEW SECRET’S CLOUDS.YAML, PAYING ATTENTION TO THE
    INDENTATIONS>
```

Once the newly created **clouds.yaml**’s contents have been copied into **credentials.yaml**, it should look something like this:

```
apiVersion: v1
kind: Secret
metadata:
  name: <MAKE SURE THIS MATCHES “cloudCredentialsSecretName:” IN configmap.yaml>
  namespace: capi-self
  annotations:
    # Allow the sealed secret controller to take over this secret after bootstrapping
    sealedsecrets.bitnami.com/managed: "true"
stringData:
  clouds.yaml: |
    clouds:
      openstack:
        auth:
          auth_url: ...
          application_credential_id: ...
          application_credential_secret: ...
        interface: ...
        identity_api_version: 3
        auth_type: ...
```

From here make sure that the terminal’s current working directory is in the same one as **credentials.yaml**, `clusters/<cluster-name>/` from the repo root, and then run the following Kubeseal command:

```sh
kubeseal \
  --kubeconfig kubeconfig \
  --format yaml \
  --controller-name sealed-secrets \
  --controller-namespace sealed-secrets-system \
  --secret-file credentials.yaml  \
  --sealed-secret-file encrypted-creds.yaml
```

> [!NOTE]
> This will create a new file named 'encrypted-creds.yaml' containing the encrypted contents and will need to be renamed to 'credentials.yaml'. This is just to be safe, however this step can be avoided by replacing 'encrypted-creds.yaml' with 'credentials.yaml' in the above command.

### **Updating Secrets**

With the new secrets encrypted it is time to change the sealed secret which is on the kubernetes cluster.

The process of changing the secret over is as simple as adding, committing and pushing the new **credentials.yaml** to the upstream GitHub repository which is being tracked by FluxCD.

> [!TIP]
> It is highly recommended to `git switch -c` to a new branch when pushing the new credentials.yaml so that a pull request can be reviewed before merging to the tracked branch.

When the new **credentials.yaml** has been merged into the FluxCD tracked repository branch, FluxCD will try to update the **sealed secret** on the self managed cluster once it recognises that there are differences between the cluster’s current configuration and the one on GitHub.

> [!NOTE]
> The time interval in which FluxCD will check for these *drifts between configurations* is set in the cluster’s **helmrelease.yaml** found within the `fluxcd-config/components/<cluster-name>/` directory, under the `interval` variable.

This should result in the **sealed secret** on the Kubernetes cluster containing the new secret. The `sealed-secrets` controller on the cluster will then convert this to a standard k8s secret which can be [decoded](https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/#decoding-secret) using `kubectl` or `k9s` to check that the contents has been updated correctly.

###	**Deleting Old Secrets**

Once the sealed secret has been updated on kubernetes it is time to do some *housekeeping* by now deleting the old credentials and unnecessary files created along the way, such as **old-credentials.yaml** and its corresponding application credential on Horizon.

By following the steps outlined in **Create/Delete Credentials**, the option to delete application credentials can be found.

Do note that in the scenario where the secret has been compromised, this should be the first step completed; this is because doing so invalidates the credential posing the security threat and prevents any operations using those credentials from being authenticated. Apart from this, and no longer needing to rename **credentials.yaml** to **old-credentials.yaml**, all other steps are the same.

###	**Rotating Compromised Secrets**
As mentioned above, an application credential which is a security concern should be deleted before any other step; after which a new application credential, which will replace it, can be created.

> [!IMPORTANT]
> Don’t forget to download the ```clouds.yaml``` file after creating the new application credential\!

Due to having deleted the old application credentials there is no need to rename the **credentials.yaml** file and can instead be directly replaced with the template, plus the contents of the new application credential’s **clouds.yaml**.

```
apiVersion: v1
kind: Secret
metadata:
  name: <MAKE SURE THIS MATCHES “cloudCredentialsSecretName:” IN configmap.yaml>
  namespace: capi-self
  annotations:
    # Allow the sealed secret controller to take over this secret after bootstrapping
    sealedsecrets.bitnami.com/managed: "true"
stringData:
  clouds.yaml: |
    clouds:
      openstack:
        auth:
          auth_url: ...
          application_credential_id: ...
          application_credential_secret: ...
        interface: ...
        identity_api_version: 3
        auth_type: ...
```

Then, much like the previous secret rotation, use Kubeseal to encrypt the new secret. This time round, the Kubeseal command below will seal the secret and overwrite **credentials.yaml** rather than create an intermediate **encrypted-creds.yaml** file.

```sh
kubeseal \
  --kubeconfig kubeconfig \
  --format yaml \
  --controller-name sealed-secrets \
  --controller-namespace sealed-secrets-system \
  --secret-file credentials.yaml  \
  --sealed-secret-file credentials.yaml
```

Again, this file will then be added, committed and pushed to a preferably new, GitHub branch which can then be reviewed and merged into the branch which FluxCD is tracking for changes. After which, once per interval, FluxCD will compare the current configuration with the branch on GitHub, and upon noticing any differences will attempt to update the current cluster’s configuration to reflect the changes.

# **Validate Configuration**

It is always a good idea to test your deployments for any potential risks or errors, which can lead to more issues further down the line. Therefore, it is worthwhile to validate the Kubernetes cluster both with a diagnostic tool and by checking the pods' ```STATUS```.

###	**Pod Status**

A quick and simple way of checking the results of the secret rotation is to check the ```STATUS``` and, if necessary, logs of the pods. This can be done by running

```sh
kubectl get pods -A
```

then checking for any pods which may be labelled with ```Error``` or ```CrashLoopBackOff```. If this is the case check the logs of that pod by running

```sh
kubectl logs <pod-name> -n <namespace>
```

> [!TIP]
> This is where using k9s can be very useful, as it allows for a more interactive and easier way to check the status of pods and follow their logs.

For general help with debugging Cluster API clusters please visit our debugging guide [here](https://github.com/azimuth-cloud/capi-helm-charts/blob/main/charts/openstack-cluster/DEBUGGING.md).

###	**Sonobuoy**

The official documentation can be found [here](https://sonobuoy.io/docs/v0.57.1/), however a brief outline will be explained below.

Once Sonobuoy has been installed, and making sure that the terminal’s working directory is set to the `fluxcd-config` directory, as well as, the appropriate cluster’s **kubeconfig** being exported; a **single** default conformance test can be run with:

```
sonobuoy run --wait --mode quick
```

Once complete, export the results with:

```
results=$(sonobuoy retrieve)
```

Then inspect them with:

```
sonobuoy results $results
```

This will display various information, however, all that is of interest at this point are the details under **Run Details** which should, hopefully, report 100% **Node** and **Pod** health.

The ```results``` command has many useful options, for which further information can be found [here](https://sonobuoy.io/docs/v0.57.1/results/).