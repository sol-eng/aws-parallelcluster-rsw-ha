# Setup for auxiliary services

```
just key-pair-new
pulumi stack init benchmark
pulumi config set email my-email@posit.co
pulumi config set interpreter <path-to-bash>
# Set the correct billing code, benchmarking for load testing or ukhsa for customer diagnostics
pulumi config set billing_code <billing_code for effort>
just create-secrets
just up 
```
