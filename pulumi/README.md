# Setup for auxiliary services

```
just key-pair-new
pulumi stack init benchmark
pulumi config set email my-email@posit.co
pulumi config set interpreter <path-to-bash>
just create-secrets
just up 
```
