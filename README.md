## Charts

* [CA-Overprovioner](https://github.com/seagits/helm-charts/tree/master/charts/ca-overprovisioner)
* [Application](https://github.com/seagits/helm-charts/tree/master/charts/application)

## Prerequisites

[Helm](https://helm.sh) must be installed to use the charts.  Please refer to
Helm's [documentation](https://helm.sh/docs) to get started.

## Usage

Once Helm has been set up correctly, add the repo as follows:

```
  helm repo add seagits https://seagits.github.io/helm-charts
```

If you had already added this repo earlier, run `helm repo update` to retrieve
the latest versions of the packages.  You can then run `helm search repo
<alias>` to see the charts.

To install the <chart-name> chart:

```
    helm install my-<chart-name> seagits/<chart-name>
```

In general, each of the charts documents its input in `values.yaml` file. You can access the values.yaml of a Chart either by inspecting this repository, or using the helm `inspect` command:

```
helm inspect values seagits/<helm-chart>
```


To install the <chart-name> with a custom `values.yml`. In other words, pass parameters to the chart:

```
helm install my-<chart-name> -f values.yml seagits/<chart-name>
```

To uninstall the chart:

```
    helm delete my-<chart-name>
```
