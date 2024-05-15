# Setup for auxiliary services

```
pulumi stack init daily-2024-04-1-748-pro2
pulumi config set email my-email@posit.co
pulumi config set rsw-ha:billing_code ukhsa
just create-secrets
just up 
```

Note: it is important to use the same name for the pulumi stack than you will use for the parallelcluster deployment name. 
