# Setup for auxiliary services

```
just key-pair-new
pulumi stack init benchmark
pulumi config set email my-email@posit.co
just create-secrets
just up 
```
