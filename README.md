# k8s_cluster

Install k8s cluster just using `vagrant up`

## Pre-install

### Vagrantfile

    - Make sure `privateIP` in `Vagrantfile` is available.
    - Make sure `privateIP` in `Vagrantfile` is equal to `clusterIPPrefix` in `install.bash`.

### install.bash

    - Modify `netIF` and `clusterIPPrefix` if not correct.
    - Modify `clusterName` and other const variables if you want.

## Install

    - Execute `vagrant up`.