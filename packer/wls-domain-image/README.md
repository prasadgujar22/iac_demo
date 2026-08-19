# Packer — WebLogic domain image

Builds the Model-in-Image domain image consumed by `terraform/20-wls-k8s`.

```bash
packer init  .
packer validate -var image_tag=2.0 .
packer build  -var image_tag=2.0 .
```

## Guard rail

The build **fails deliberately** if the WDT model declares a
`JDBCSystemResource`. A baked-in datasource is re-initialised on every pod start;
if its database is unreachable the managed servers enter ADMIN mode and no
application can deploy. This exact fault previously took the whole domain down,
so it is enforced at build time rather than discovered at runtime.

Datasources belong in the application, configured from environment variables.

## Is this stage required?

Not for every run. `wls-domain-image:1.6` already exists on the host and is
usable as-is. Rebuild only when the domain **topology** changes (cluster name,
server count, ports, JVM args). Application changes never need a rebuild —
the WAR is deployed separately by Ansible.

The Jenkins pipeline therefore has a `BUILD_IMAGE` parameter, default `false`.
