# aws-parallelcluster-rsw-ha

This is a repository that highlights a possible integration of Posit Workbench into AWS ParallelCluster. The main focus is on high availability and hence for resiliency of the system against failure. This repository allows for a complete setup without any additional dependencies.

The repository consists of a couple of sub folders containing

-   [Documentation](docs/PWB.pdf)
-   [Pulumi recipes for auxiliary infrastructure](pulumi/)
-   [Custom AMI generation](image/)
-   [AWS ParallelCluster](parallelcluster/)

Users are advised to read through the docs and follow the instructions there. The typical order of execution is

1.  Pulumi recipes
2.  Custom AMI
3.  AWS ParallelCluster setup
