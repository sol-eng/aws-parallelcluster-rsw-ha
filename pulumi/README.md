# Setup for auxiliary services

```
just key-pair-new
pulumi stack init benchmark
pulumi config set email my-email@posit.co
pulumi config set rsw-ha:billing_code ukhsa
just create-secrets
just up 
```
