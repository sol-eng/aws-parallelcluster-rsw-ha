# Python setup

```
# This folder is managed by uv, please run the following command to initialize the .venv

uv sync

# You may also need to run:

uv self update

# If your version of uv is not able to find Python 3.12.11
```


# Setup for auxiliary services

```
pulumi stack init daily-2024-04-1-748-pro2
pulumi config set email my-email@posit.co
pulumi config set billing_code ukhsa
pulumi config set my_ip `curl ifconfig.me`
pulumi up 
```

Note: it is important to use the same name for the pulumi stack than you will use for the parallelcluster deployment name. 
