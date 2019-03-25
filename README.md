# Wordpress Azure - A CNAB to deploy wordpress on Azure  

This CNAB creates an installation of wordpress on Azure with optiona features such as Custom DNS , MySQL database etc..

To test:

```console
$ duffle creds generate -f ./bundle.json terraform
$ edit $HOME/.duffle/credentials/terraform.yaml
$ duffle install -c terraform -f bundle.json my-terraform-test
```

To use this as a base image:

```Dockerfile
FROM cnab/terraform:latest

COPY my/terraform/dir /cnab/app/tf
# Copy your Dockerfile and bundle.json, too
```
